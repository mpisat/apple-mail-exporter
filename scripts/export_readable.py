#!/usr/bin/env python3
"""Export local Apple Mail through native persistent conversion workers."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from email import policy
from email.parser import BytesHeaderParser
from email.utils import parsedate_to_datetime
import json
import os
from pathlib import Path
from queue import Empty, Queue
import re
import shutil
import subprocess
import threading
import time
import unicodedata


def message_metadata(source):
    with source.open('rb') as stream:
        count = int(stream.readline().strip())
        header = bytearray()
        remaining = count
        while remaining > 0:
            line = stream.readline(remaining)
            if not line:
                break
            remaining -= len(line)
            header.extend(line)
            if line in (b'\n', b'\r\n'):
                break
    parsed = BytesHeaderParser(policy=policy.default).parsebytes(bytes(header))
    subject = str(parsed.get('Subject', '')) or 'No subject'
    try:
        date = parsedate_to_datetime(str(parsed.get('Date', ''))).date()
    except (ValueError, TypeError, OverflowError):
        date = None
    return date, subject


def readable_path(root, source, sequence):
    date, subject = message_metadata(source)
    safe = re.sub(r'[<>:"/\\|?*\x00-\x1f\x7f]', '_', subject)
    safe = re.sub(r'\s+', ' ', safe).strip(' .') or 'No subject'
    identifier = f'{sequence:08d}'
    prefix = f'{date.isoformat()} - ' if date else 'Undated - '
    suffix = f'__{identifier}.eml'
    budget = 255 - len((prefix + suffix).encode('utf-8'))
    # macOS may expose decomposed names even when the share stores composed Unicode.
    # Budget the longer canonical form so both representations fit the filename limit.
    safe = unicodedata.normalize('NFD', safe)
    safe = safe.encode('utf-8', errors='replace')[:budget].decode('utf-8', errors='ignore').rstrip(' .')
    safe = unicodedata.normalize('NFC', safe)
    folder = root / f'{date.year:04d}' / f'{date.month:02d}' if date else root / 'Undated'
    return folder / (prefix + safe + suffix), subject, date.isoformat() if date else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=Path.home() / 'Library/Mail')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--worker', type=Path, required=True)
    parser.add_argument('--priority-account', default='')
    parser.add_argument('--control', type=Path, required=True)
    parser.add_argument('--workers', type=int, default=8)
    args = parser.parse_args()
    if args.workers < 1:
        parser.error('--workers must be positive')
    os.umask(0o077)
    source = args.source.resolve()
    output = args.output.resolve()
    if output == source or source in output.parents:
        parser.error('The output must be outside the source Mail tree')
    args.control.mkdir(mode=0o700, parents=True, exist_ok=False)
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    files = []
    scan_errors = []
    for directory, dirs, names in os.walk(source, followlinks=False, onerror=lambda error: scan_errors.append(str(error))):
        dirs[:] = [name for name in dirs if name != 'Attachments']
        for name in names:
            if name.lower().endswith('.emlx'):
                files.append(Path(directory) / name)
    files.sort(key=lambda path: (args.priority_account not in path.relative_to(source).parts,
                                 str(path.relative_to(source))))
    work = Queue()
    for number, path in enumerate(files, 1):
        work.put((number, path))
    lock = threading.Lock()
    state = {'status': 'running', 'coordinator_pid': os.getpid(), 'source': str(source), 'output': str(output),
             'priority_account': args.priority_account, 'expected': len(files),
             'started_unix': time.time(), 'processed': 0, 'exported': 0, 'failed': 0,
             'scan_errors': scan_errors, 'accounts': {}, 'worker_pids': []}
    report_path = args.control / 'export-report.jsonl'
    report = report_path.open('w', encoding='utf-8', buffering=1)

    def persist():
        temporary = args.control / 'state.tmp'
        temporary.write_text(json.dumps(state, indent=2))
        temporary.replace(args.control / 'state.json')

    def record(row):
        with lock:
            report.write(json.dumps(row, ensure_ascii=False) + '\n')
            state['processed'] += 1
            state[row['status']] += 1
            account = row['account']
            counts = state['accounts'].setdefault(account, {'processed': 0, 'exported': 0, 'failed': 0})
            counts['processed'] += 1
            counts[row['status']] += 1
            if state['processed'] % 100 == 0:
                persist()

    def worker(number):
        with (args.control / f'worker-{number}.log').open('wb') as errors:
            process = subprocess.Popen([str(args.worker), str(output), str(len(files))],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors,
                                       text=True, encoding='utf-8', bufsize=1)
            with lock:
                state['worker_pids'].append(process.pid)
                persist()
            try:
                for _ in range(len(files)):
                    if process.poll() is not None:
                        break
                    try:
                        sequence, path = work.get_nowait()
                    except Empty:
                        break
                    relative = path.relative_to(source)
                    parts = relative.parts
                    account = parts[1] if len(parts) > 1 and parts[0].startswith('V') else parts[0]
                    row = {'source': str(path), 'source_relative': str(relative), 'account': account,
                           'original_id': path.name.split('.')[0], 'id': f'{sequence:08d}'}
                    try:
                        target, subject, date = readable_path(output, path, sequence)
                        row.update(output=str(target), subject=subject, date=date)
                    except Exception as error:
                        row.update(status='failed', reason='metadata_error', detail=str(error))
                        record(row)
                        work.task_done()
                        continue
                    try:
                        process.stdin.write(json.dumps({'source': str(path), 'output': str(target)}) + '\n')
                        process.stdin.flush()
                        response = process.stdout.readline()
                        if not response:
                            raise RuntimeError('Native conversion worker exited without a result')
                        row.update(json.loads(response))
                    except Exception as error:
                        row.update(status='failed', reason='worker_exited', detail=str(error))
                        record(row)
                        work.task_done()
                        break
                    record(row)
                    work.task_done()
            finally:
                try:
                    process.stdin.close()
                except (BrokenPipeError, OSError):
                    pass
                code = process.wait()
                with lock:
                    state.setdefault('worker_exit_codes', []).append(code)
                    persist()

    with lock:
        persist()
    print(json.dumps({'output': str(output), 'messages': len(files), 'priority_account': args.priority_account}), flush=True)
    try:
        with ThreadPoolExecutor(max_workers=args.workers) as executor:
            list(executor.map(worker, range(args.workers)))
    finally:
        report.close()
    with lock:
        state.update(status='completed', finished_unix=time.time(), unprocessed=work.qsize())
        persist()
    shutil.copyfile(report_path, output / 'export-report.jsonl')
    (output / 'summary.json').write_text(json.dumps(state, indent=2))
    print(json.dumps(state), flush=True)
    if state['failed'] or state['scan_errors'] or state['unprocessed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
