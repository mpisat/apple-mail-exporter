#!/usr/bin/env python3
"""Convert a complete readable EML export to a separate new Markdown tree."""
import argparse
import base64
import binascii
from concurrent.futures import ThreadPoolExecutor
from email import policy
from email.parser import BytesHeaderParser
from html.parser import HTMLParser
import json
import mimetypes
import os
from pathlib import Path
from queue import Empty, Queue
import quopri
import re
import tempfile
import threading
import time
import unicodedata
from urllib.parse import quote, unquote


class ConversionError(Exception):
    def __init__(self, reason, detail):
        super().__init__(detail)
        self.reason = reason


def safe_name(value):
    value = ''.join('_' if unicodedata.category(char).startswith('C') or char in '<>:"/\\|?*'
                    else char for char in value)
    return re.sub(r'\s+', ' ', value).strip(' .')


def name_bytes(value):
    return max(len(unicodedata.normalize(form, value).encode('utf-8')) for form in ('NFC', 'NFD'))


def shorten(value, budget):
    result = []
    for char in value:
        candidate = ''.join(result) + char
        if name_bytes(candidate) > budget:
            break
        result.append(char)
    return unicodedata.normalize('NFC', ''.join(result)).rstrip(' .')


def decode_payload(headers, body):
    encoding = str(headers.get('Content-Transfer-Encoding', '7bit')).lower().strip()
    try:
        if encoding == 'base64':
            return base64.b64decode(re.sub(rb'\s+', b'', body), validate=True)
        if encoding == 'quoted-printable':
            if re.search(rb'=(?![0-9A-Fa-f]{2}|\r?\n|$)', body):
                raise ValueError('Invalid quoted-printable escape')
            return quopri.decodestring(body)
        if encoding not in ('7bit', '8bit', 'binary', ''):
            raise ValueError(f'Unsupported transfer encoding: {encoding}')
        return body
    except (ValueError, binascii.Error) as error:
        raise ConversionError('decode_error', str(error)) from error


class Part:
    """Retain raw leaf bodies: Message.as_bytes() would rewrite attached mail."""
    def __init__(self, raw, body_root=False):
        separator = re.search(rb'\r?\n\r?\n', raw)
        if separator is None:
            raise ConversionError('invalid_message', 'Missing MIME header/body separator')
        self.headers = BytesHeaderParser(policy=policy.default).parsebytes(raw[:separator.start()] + b'\r\n\r\n')
        if self.headers.defects:
            raise ConversionError('invalid_message', str(self.headers.defects))
        self.body = raw[separator.end():]
        self.kind = self.headers.get_content_type()
        self.filename = self.headers.get_filename()
        self.cid = str(self.headers.get('Content-ID', '')).strip().strip('<>')
        self.attachment = (self.headers.get_content_disposition() == 'attachment'
                           or self.filename is not None or (bool(self.cid) and not body_root)
                           or (not self.kind.startswith('multipart/') and self.kind not in ('text/plain', 'text/html')))
        self.children = []
        if self.kind.startswith('multipart/') and not self.attachment:
            boundary = self.headers.get_boundary()
            if not boundary:
                raise ConversionError('invalid_message', 'Multipart has no boundary')
            delimiters = list(re.finditer(rb'(?m)^--' + re.escape(boundary.encode('ascii'))
                                         + rb'(--)?[ \t]*(?:\r?\n|$)', self.body))
            if not delimiters or not delimiters[-1].group(1):
                raise ConversionError('invalid_message', 'Multipart closing boundary is missing')
            for current, following in zip(delimiters, delimiters[1:]):
                if current.group(1):
                    break
                child = self.body[current.end():following.start()]
                # The newline immediately preceding a MIME delimiter belongs to it,
                # not to the payload. Preserve every earlier byte verbatim.
                if child.endswith(b'\r\n'):
                    child = child[:-2]
                elif child.endswith(b'\n'):
                    child = child[:-1]
                related_root = False
                if self.kind == 'multipart/related':
                    start = self.headers.get_param('start')
                    if start:
                        child_headers = BytesHeaderParser(policy=policy.default).parsebytes(child)
                        related_root = str(child_headers.get('Content-ID', '')).strip().strip('<>') == start.strip('<>')
                    else:
                        related_root = not self.children
                self.children.append(Part(child, body_root=related_root))

    def has_plain_body(self):
        if self.attachment:
            return False
        return self.kind == 'text/plain' or any(child.has_plain_body() for child in self.children)


def collect(part, attachments):
    if part.attachment:
        extension = '.eml' if part.kind == 'message/rfc822' else mimetypes.guess_extension(part.kind, strict=False)
        extension = {'.jpe': '.jpg', '.jpeg': '.jpg'}.get(extension, extension) or '.bin'
        original = part.filename
        name = safe_name(original or f'attachment{extension}') or f'attachment{extension}'
        attachments.append({'original_name': original, 'name': name, 'content_type': part.kind,
                            'cid': part.cid, 'bytes': decode_payload(part.headers, part.body)})
        return []
    if part.children:
        rendered = [collect(child, attachments) for child in part.children]
        if part.kind == 'multipart/alternative':
            preferred = next((index for index, child in enumerate(part.children) if child.has_plain_body()), None)
            if preferred is None:
                preferred = next((index for index, blocks in enumerate(rendered) if blocks), None)
            return rendered[preferred] if preferred is not None else []
        return [block for blocks in rendered for block in blocks]
    payload = decode_payload(part.headers, part.body)
    charset = part.headers.get_content_charset()
    try:
        if charset:
            text = payload.decode(charset)
        else:
            try:
                text = payload.decode('utf-8')
            except UnicodeDecodeError:
                text = payload.decode('iso-8859-1')
    except (UnicodeError, LookupError) as error:
        raise ConversionError('decode_error', str(error)) from error
    return [(part.kind, text)]


def markdown_text(value):
    return re.sub(r'([\\`*_[\]<>])', r'\\\1', value.replace('\x00', ''))


class HTMLMarkdown(HTMLParser):
    def __init__(self, cids):
        super().__init__(convert_charrefs=True)
        self.cids = cids
        self.output = []
        self.links = []
        self.ignored = 0
        self.pre = 0

    def handle_starttag(self, tag, attributes):
        attributes = dict(attributes)
        if tag in ('script', 'style', 'head'):
            self.ignored += 1
        if self.ignored:
            return
        if tag in ('p', 'div', 'section', 'article', 'tr', 'blockquote'):
            self.output.append('\n\n')
        elif re.fullmatch(r'h[1-6]', tag):
            self.output.append('\n\n' + '#' * int(tag[1]) + ' ')
        elif tag == 'br':
            self.output.append('\n')
        elif tag == 'li':
            self.output.append('\n- ')
        elif tag in ('strong', 'b'):
            self.output.append('**')
        elif tag in ('em', 'i'):
            self.output.append('*')
        elif tag == 'pre':
            self.pre += 1
            self.output.append('\n\n```\n')
        elif tag == 'a':
            href = self.target(attributes.get('href', ''))
            self.links.append(href)
            if href:
                self.output.append('[')
        elif tag == 'img':
            src = attributes.get('src', '')
            label = markdown_text(attributes.get('alt', '') or 'image')
            target = self.target(src)
            if target:
                prefix = '!' if src.lower().startswith('cid:') else ''
                self.output.append(f'{prefix}[{label}]({target})')
            else:
                self.output.append(label)
        elif tag in ('td', 'th'):
            self.output.append(' ')

    def handle_startendtag(self, tag, attributes):
        self.handle_starttag(tag, attributes)
        if tag not in ('img', 'br', 'hr', 'meta', 'link', 'input'):
            self.handle_endtag(tag)

    def target(self, value):
        if value.lower().startswith('cid:'):
            name = self.cids.get(unquote(value[4:]).strip('<>'))
            return quote(name, safe='') if name else ''
        # Preserve external web/mail links without fetching them. Relative HTML
        # resources have no source file to point at in this separate export.
        if re.match(r'(?i)^(https?://|mailto:)', value):
            return quote(value, safe=':/?#@!$&\'=+%,;-._~')
        return ''

    def handle_endtag(self, tag):
        if tag in ('script', 'style', 'head'):
            self.ignored = max(0, self.ignored - 1)
            return
        if self.ignored:
            return
        if tag == 'a' and self.links:
            href = self.links.pop()
            if href:
                self.output.append(f']({href})')
        elif tag in ('strong', 'b'):
            self.output.append('**')
        elif tag in ('em', 'i'):
            self.output.append('*')
        elif tag == 'pre':
            self.pre = max(0, self.pre - 1)
            self.output.append('\n```\n\n')
        elif tag in ('p', 'div', 'section', 'article', 'tr', 'blockquote') or re.fullmatch(r'h[1-6]', tag):
            self.output.append('\n\n')

    def handle_data(self, data):
        if not self.ignored:
            self.output.append(data if self.pre else markdown_text(re.sub(r'\s+', ' ', data)))

    def render(self, text):
        self.feed(text)
        self.close()
        return re.sub(r'\n[ \t]*\n(?:[ \t]*\n)+', '\n\n', ''.join(self.output)).strip()


def output_names(source, subject, attachments):
    match = re.fullmatch(r'(\d{4}-\d{2}-\d{2}|Undated) - .*__([^/]+)\.eml', source.name, re.IGNORECASE)
    if not match:
        raise ConversionError('invalid_source_name', 'Expected readable DATE - Subject__ID.eml filename')
    date, identifier = match.groups()
    if safe_name(identifier) != identifier:
        raise ConversionError('invalid_source_name', 'Unsafe source ID')
    prefix, suffix = date + ' - ', '__' + identifier
    safe_subject = safe_name(subject) or 'No subject'
    fixed = name_bytes(prefix + suffix)
    subject_budget = 255 - fixed - len('.md')
    # Share only the space that actually needs truncating. The common subject
    # budget is the strictest requirement across all this message's filenames.
    for index, attachment in enumerate(attachments, 1):
        name = attachment['name']
        extension = Path(name).suffix
        basename = name[:-len(extension)] if extension else name
        marker = f'_att_{index:02d}_'
        available = 255 - fixed - name_bytes(marker + extension)
        total = name_bytes(safe_subject) + name_bytes(basename)
        if available < 2:
            raise ConversionError('filename_too_long', 'Date, ID and attachment extension exceed filename limit')
        subject_budget = min(subject_budget, available if total <= available else
                             max(name_bytes(safe_subject[0]), available * name_bytes(safe_subject) // total))
    shortened_subject = shorten(safe_subject, subject_budget)
    if not shortened_subject:
        raise ConversionError('filename_too_long', 'Date and ID leave no room for the subject')
    stem = prefix + shortened_subject + suffix
    for index, attachment in enumerate(attachments, 1):
        name = attachment['name']
        extension = Path(name).suffix
        basename = name[:-len(extension)] if extension else name
        marker = f'_att_{index:02d}_'
        budget = 255 - name_bytes(stem + marker + extension)
        truncated = shorten(basename, budget)
        if not truncated:
            raise ConversionError('filename_too_long', 'No room for attachment filename')
        attachment['name'] = stem + marker + truncated + extension
    return stem, identifier, date


def atomic_create(path, payload):
    descriptor, temporary = tempfile.mkstemp(prefix='.markdown-', suffix='.tmp', dir=path.parent)
    try:
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(payload)
        # A hard link publishes a complete file while refusing an existing name.
        os.link(temporary, path)
    finally:
        os.unlink(temporary)


def convert(source, input_root, output_root, metadata):
    row = {'source': str(source), 'source_relative': str(source.relative_to(input_root)),
           'account': metadata.get('account', ''), 'original_source': metadata.get('source'),
           'status': 'failed'}
    created = []
    try:
        part = Part(source.read_bytes(), body_root=True)
        subject = str(part.headers.get('Subject', '')) or 'No subject'
        attachments = []
        blocks = collect(part, attachments)
        stem, identifier, date = output_names(source, subject, attachments)
        folder = output_root / source.relative_to(input_root).parent
        folder.mkdir(mode=0o700, parents=True, exist_ok=True)
        target = folder / (stem + '.md')
        row.update(subject=subject, id=identifier, date=date, output=str(target), attachments=[])
        cids = {attachment['cid']: attachment['name'] for attachment in attachments if attachment['cid']}
        body = '\n\n'.join(HTMLMarkdown(cids).render(text) if kind == 'text/html' else text.strip()
                           for kind, text in blocks)
        headers = ['# ' + markdown_text(subject), '']
        for header in ('From', 'To', 'Cc', 'Bcc', 'Date', 'Message-ID'):
            if part.headers.get(header):
                headers.append(f'**{header}:** ' + markdown_text(str(part.headers[header])))
        headers.extend(['**Source EML:** ' + markdown_text(str(source.relative_to(input_root))),
                        '**Source ID:** ' + markdown_text(identifier)])
        if row['account']:
            headers.append('**Account:** ' + markdown_text(row['account']))
        document = '\n'.join(headers) + '\n\n' + body + '\n'
        if attachments:
            document += '\n## Attachments\n\n'
        for attachment in attachments:
            path = folder / attachment['name']
            label = attachment['original_name'] or f"Unnamed {attachment['content_type']} attachment"
            document += f"- [{markdown_text(label)}]({quote(path.name, safe='')})\n"
            row['attachments'].append({'output': str(path), 'original_name': attachment['original_name'],
                                       'content_type': attachment['content_type'], 'bytes': len(attachment['bytes'])})
        for attachment in attachments:
            path = folder / attachment['name']
            atomic_create(path, attachment['bytes'])
            created.append(path)
        atomic_create(target, document.encode('utf-8'))
        created.append(target)
        row['status'] = 'exported'
    except Exception as error:
        for path in reversed(created):
            path.unlink()
        reason = error.reason if isinstance(error, ConversionError) else ('output_exists' if isinstance(error, FileExistsError) else 'conversion_error')
        row.update(status='failed', reason=reason, detail=str(error))
    return row


def path_key(path):
    return unicodedata.normalize('NFC', str(path.resolve()))


def input_metadata(path, input_root):
    mapping = {}
    if path:
        with path.open(encoding='utf-8') as stream:
            for line in stream:
                row = json.loads(line)
                if row.get('output') and row.get('status') == 'exported':
                    source = Path(row['output'])
                    if not source.is_absolute():
                        source = input_root / source
                    mapping[path_key(source)] = row
    return mapping


def replace_state(path, state):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(state, indent=2, ensure_ascii=False), encoding='utf-8')
    temporary.replace(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--control', type=Path, required=True)
    parser.add_argument('--input-report', type=Path)
    parser.add_argument('--priority-account', default='')
    parser.add_argument('--workers', type=int, default=8)
    args = parser.parse_args()
    if args.workers < 1:
        parser.error('--workers must be positive')
    source, output, control = (path.resolve() for path in (args.input, args.output, args.control))
    if not source.is_dir():
        parser.error('invalid_input: --input must be an existing EML directory')
    if (output == source or source in output.parents or control == source or source in control.parents
            or output == control or output in control.parents or control in output.parents):
        parser.error('unsafe_output: output and control must be separate and outside input')
    if output.exists() or output.is_symlink():
        parser.error('output_exists: --output must be new')
    if control.exists() or control.is_symlink():
        parser.error('control_exists: --control must be new')
    try:
        metadata = input_metadata(args.input_report, source)
    except (OSError, ValueError, TypeError) as error:
        parser.error(f'invalid_input_report: {error}')
    os.umask(0o077)
    control.mkdir(mode=0o700, parents=True, exist_ok=False)
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    files, scan_errors = [], []
    for directory, dirs, names in os.walk(source, followlinks=False, onerror=lambda error: scan_errors.append(str(error))):
        for name in names:
            path = Path(directory) / name
            if name.lower().endswith('.eml'):
                if path.is_symlink():
                    scan_errors.append(f'Symlink EML skipped: {path}')
                else:
                    files.append(path)
    files.sort(key=lambda path: (bool(args.priority_account) and metadata.get(path_key(path), {}).get('account') != args.priority_account,
                                 str(path.relative_to(source))))
    work = Queue()
    for path in files:
        work.put(path)
    state = {'status': 'running', 'coordinator_pid': os.getpid(), 'input': str(source), 'output': str(output),
             'priority_account': args.priority_account, 'workers': args.workers, 'expected': len(files),
             'started_unix': time.time(), 'processed': 0, 'exported': 0, 'failed': 0,
             'scan_errors': scan_errors, 'accounts': {}}
    lock = threading.Lock()
    report_path = control / 'export-report.jsonl'
    print(json.dumps({'output': str(output), 'messages': len(files), 'workers': args.workers}), flush=True)
    replace_state(control / 'state.json', state)
    with report_path.open('x', encoding='utf-8', buffering=1) as report:
        def worker():
            for _ in range(len(files)):
                try:
                    path = work.get_nowait()
                except Empty:
                    return
                row = convert(path, source, output, metadata.get(path_key(path), {}))
                with lock:
                    report.write(json.dumps(row, ensure_ascii=False) + '\n')
                    state['processed'] += 1
                    state[row['status']] += 1
                    counts = state['accounts'].setdefault(row['account'], {'processed': 0, 'exported': 0, 'failed': 0})
                    counts['processed'] += 1
                    counts[row['status']] += 1
                    replace_state(control / 'state.json', state)
                    if state['processed'] % 100 == 0:
                        print(json.dumps({key: state[key] for key in ('processed', 'exported', 'failed')}), flush=True)
                work.task_done()
        with ThreadPoolExecutor(max_workers=args.workers) as executor:
            list(executor.map(lambda _: worker(), range(args.workers)))
    state.update(status='completed', finished_unix=time.time(), unprocessed=work.qsize())
    replace_state(control / 'state.json', state)
    atomic_create(output / 'export-report.jsonl', report_path.read_bytes())
    atomic_create(output / 'summary.json', json.dumps(state, indent=2, ensure_ascii=False).encode('utf-8'))
    print(json.dumps(state), flush=True)
    return int(bool(state['failed'] or scan_errors or state['unprocessed']))


if __name__ == '__main__':
    raise SystemExit(main())
