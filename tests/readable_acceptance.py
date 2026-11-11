#!/usr/bin/env python3
"""Production-entrypoint checks for readable EML export."""
from email import policy
from email.header import Header
from email.parser import BytesParser
import json
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory


def main():
    worker = Path(sys.argv[1]).resolve()
    runner = Path(__file__).resolve().parents[1] / 'scripts/export_readable.py'
    with TemporaryDirectory(prefix='readable-mail-test-') as temporary:
        root = Path(temporary)
        source = root / 'Mail'
        output = root / 'Readable'
        message = b'Date: Mon, 18 Mar 2024 12:00:00 +0000\r\nSubject: Invoice/March\r\n\r\nbody\r\n'

        def write(relative, payload):
            path = source / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(str(len(payload)).encode() + b'\n' + payload)
            return path

        write('V10/other/INBOX.mbox/Messages/1.emlx', message)
        write('V10/priority/Archive.mbox/Messages/2.emlx', message)
        write('V10/priority/Archive.mbox/Messages/3.emlx', b'From: b@example.test\r\n\r\nundated\r\n')
        calendar = (b'Date: Mon, 18 Mar 2024 12:00:00 +0000\r\nSubject: Calendar\r\n'
                    b'Content-Type: text/calendar\r\nContent-Transfer-Encoding: 7bit\r\n'
                    b'X-Apple-Content-Length: 32\r\n\r\n')
        path = write('V10/priority/Archive.mbox/Messages/4.partial.emlx', calendar)
        slot = path.parent.parent / 'Attachments/4/1'
        slot.mkdir(parents=True)
        raw = b'BEGIN:VCALENDAR\nEND:VCALENDAR\n'
        (slot / 'invite.ics').write_bytes(raw)
        nested = b'From: attached@example.test\r\nSubject: Nested email\r\n\r\nComplete attached content\r\n'
        attached = (b'Date: Mon, 18 Mar 2024 12:00:00 +0000\r\nSubject: Attached email\r\n'
                    b'Content-Type: message/rfc822\r\nContent-Transfer-Encoding: binary\r\n'
                    b'X-Apple-Content-Length: 3\r\n\r\n')
        path = write('V10/priority/Archive.mbox/Messages/5.partial.emlx', attached)
        slot = path.parent.parent / 'Attachments/5/1'
        slot.mkdir(parents=True)
        (slot / 'attached.eml').write_bytes(nested)
        long_subject = 'café' * 150
        long_headers = ('Date: Mon, 18 Mar 2024 12:00:00 +0000\r\nSubject: '
                        + Header(long_subject, 'utf-8').encode(linesep='\r\n') + '\r\n\r\nbody\r\n').encode()
        write('V10/priority/Archive.mbox/Messages/7.emlx', long_headers)
        result = subprocess.run([sys.executable, str(runner), '--source', str(source), '--output', str(output),
                                 '--control', str(root / 'control'), '--worker', str(worker),
                                 '--priority-account', 'priority', '--workers', '1'], capture_output=True, timeout=60)
        assert result.returncode == 0, (result.stdout, result.stderr)
        files = list(output.rglob('*.eml'))
        assert len(files) == 6
        assert len(list((output / '2024/03').glob('2024-03-18 - Invoice_March__*.eml'))) == 2
        assert len(list((output / 'Undated').glob('Undated - No subject__*.eml'))) == 1
        assert not list(output.rglob('*.mbox'))
        rows = [json.loads(line) for line in (output / 'export-report.jsonl').read_text().splitlines()]
        assert rows[0]['account'] == 'priority'
        assert next(row for row in rows if row['original_id'] == '7')['subject'] == long_subject
        path = next(path for path in files if 'Calendar' in path.name)
        assert BytesParser(policy=policy.default).parsebytes(path.read_bytes()).get_payload(decode=True) == raw
        path = next(path for path in files if 'Attached email' in path.name)
        assert nested in path.read_bytes()
        assert BytesParser(policy=policy.default).parsebytes(path.read_bytes()).get_payload()[0]['Subject'] == 'Nested email'
        assert all(len(path.name.encode()) <= 255 for path in files)

        # The native entrypoint rejects unsafe paths and continues to the next valid job.
        safe = output / '2024/03/2024-03-18 - Safe__99999999.eml'
        outside = root / 'escaped.eml'
        jobs = [{'source': str(source / 'V10/other/INBOX.mbox/Messages/1.emlx'), 'output': str(target)}
                for target in [outside, safe, safe]]
        result = subprocess.run([str(worker), str(output.resolve()), '3'],
                                input=''.join(json.dumps(job) + '\n' for job in jobs),
                                text=True, capture_output=True, timeout=60)
        assert result.returncode == 0, result.stderr
        replies = [json.loads(line) for line in result.stdout.splitlines()]
        assert replies[0]['reason'] == 'unsafe_output'
        assert replies[1]['status'] == 'exported'
        assert replies[2]['reason'] == 'output_exists'
        assert not outside.exists()
        assert safe.read_bytes() == message

        # A missing attachment must be reported explicitly while healthy mail is retained.
        write('V10/priority/Archive.mbox/Messages/6.partial.emlx', calendar)
        result = subprocess.run([sys.executable, str(runner), '--source', str(source),
                                 '--output', str(root / 'WithFailure'), '--control', str(root / 'control-failure'),
                                 '--worker', str(worker), '--workers', '2'], capture_output=True, timeout=60)
        assert result.returncode == 1, (result.stdout, result.stderr)
        rows = [json.loads(line) for line in (root / 'WithFailure/export-report.jsonl').read_text().splitlines()]
        failures = [row for row in rows if row['status'] == 'failed']
        assert len(failures) == 1 and failures[0]['reason'] == 'missing_attachment'
        assert len(list((root / 'WithFailure').rglob('*.eml'))) == 6

        exiting = root / 'exiting-worker'
        exiting.write_text('#!/usr/bin/env python3\nraise SystemExit(17)\n')
        exiting.chmod(0o700)
        result = subprocess.run([sys.executable, str(runner), '--source', str(source),
                                 '--output', str(root / 'WorkerExit'), '--control', str(root / 'control-exit'),
                                 '--worker', str(exiting), '--workers', '1'], capture_output=True, timeout=60)
        assert result.returncode == 1
        assert (root / 'WorkerExit/summary.json').exists(), result.stderr
        stopped = json.loads((root / 'WorkerExit/summary.json').read_text())
        assert stopped['processed'] <= 1 and stopped['unprocessed'] >= 6, stopped
        assert stopped['worker_exit_codes'] == [17], stopped
    print('Readable export acceptance passed: layout, priority, duplicates, cached calendars, missing parts, containment, no overwrites and continued progress.')


if __name__ == '__main__':
    main()
