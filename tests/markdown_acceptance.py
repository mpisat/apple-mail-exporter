#!/usr/bin/env python3
"""Synthetic production-entrypoint checks for Markdown export; no private mail."""
from email.header import Header
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
from tempfile import TemporaryDirectory
import unicodedata
from urllib.parse import unquote
from unittest.mock import patch


RUNNER = Path(__file__).resolve().parents[1] / 'scripts/export_markdown.py'


def run(source, output, control, *options, environment=None):
    return subprocess.run([sys.executable, str(RUNNER), '--input', str(source),
                           '--output', str(output), '--control', str(control), *options],
                          capture_output=True, text=True, timeout=60, env=environment)


def main():
    with TemporaryDirectory(prefix='markdown-mail-test-') as temporary:
        root = Path(temporary)
        source = root / 'EML'
        output = root / 'Markdown'
        paths = []

        def write(identifier, subject, body, headers=b''):
            path = source / '2024/03' / f'2024-03-18 - Source__{identifier:08d}.eml'
            path.parent.mkdir(parents=True, exist_ok=True)
            message = (b'Date: Mon, 18 Mar 2024 12:00:00 +0000\r\n'
                       b'From: Sender <sender@example.test>\r\nTo: reader@example.test\r\n'
                       + ('Subject: ' + Header(subject, 'utf-8').encode(linesep='\r\n') + '\r\n').encode()
                       + headers + b'\r\n' + body)
            path.write_bytes(message)
            paths.append(path)
            return path

        write(1, 'Plain/subject', b'Hello =E9 friend\r\n',
              b'Content-Type: text/plain; charset=iso-8859-1\r\nContent-Transfer-Encoding: quoted-printable\r\n')
        write(2, 'HTML', b'<h1>Invoice</h1><p>Visit <a href="https://example.test/a">the site</a>.</p><script>BAD SCRIPT</script>',
              b'Content-Type: text/html; charset=utf-8\r\n')
        write(3, 'Alternative', b'--alt\r\nContent-Type: text/plain\r\n\r\nPreferred plain\r\n--alt\r\nContent-Type: text/html\r\n\r\n<p>Unwanted HTML alternative</p>\r\n--alt--\r\n',
              b'Content-Type: multipart/alternative; boundary=alt\r\n')
        raw_attached = b'From: nested@example.test\r\nSubject: Raw  header\nX-Folded: first\r\n\tsecond\r\n\r\nINNER MUST STAY ATTACHED\n'
        binary = b'\x00\x01\xff\x10'
        related = (b'--mix\r\nContent-Type: multipart/related; boundary=rel; start="<htmlroot>"\r\n\r\n'
                   b'--rel\r\nContent-Type: text/html\r\nContent-ID: <htmlroot>\r\n\r\n<h2>Picture</h2><img src="cid:logo" alt="logo">\r\n'
                   b'--rel\r\nContent-Type: image/png\r\nContent-ID: <logo>\r\nContent-Transfer-Encoding: base64\r\n\r\nAAH/EA==\r\n--rel--\r\n'
                   b'--mix\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename="../../same.bin"\r\nContent-Transfer-Encoding: base64\r\n\r\nAAH/EA==\r\n'
                   b'--mix\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename="../../same.bin"\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n=00=01=FF=10\r\n'
                   b'--mix\r\nContent-Type: application/pdf\r\nContent-Disposition: attachment; filename*=utf-8\'\'caf%C3%A9.pdf\r\n\r\nPDF bytes\r\n'
                   b'--mix\r\nContent-Type: message/rfc822\r\nContent-Disposition: attachment; filename="forward.eml"\r\n\r\n'
                   + raw_attached + b'\r\n--mix--\r\n')
        write(4, 'Related and attached', related, b'Content-Type: multipart/mixed; boundary=mix\r\n')
        full_subject = 'caf\u00e9' * 150
        long_name = 'e\u0301' * 180 + '/bad\x7f.  .pdf'
        long_headers = ('Content-Type: application/pdf\r\nContent-Disposition: attachment; filename*=utf-8\'\''
                        + ''.join('%%%02X' % value for value in long_name.encode()) + '\r\n').encode()
        write(5, full_subject, b'--long\r\nContent-Type: text/plain\r\n\r\nLong subject body\r\n--long\r\n'
              + long_headers + b'\r\nlong bytes\r\n--long--\r\n', b'Content-Type: multipart/mixed; boundary=long\r\n')
        write(6, 'Nested bodies', b'--outer\r\nContent-Type: text/plain\r\n\r\nFirst body\r\n--outer\r\nContent-Type: multipart/mixed; boundary=inner\r\n\r\n--inner\r\nContent-Type: text/plain\r\n\r\nSecond body\r\n--inner\r\nContent-Type: application/pdf\r\nContent-Disposition: attachment\r\n\r\nnameless PDF\r\n--inner--\r\n--outer--\r\n',
              b'Content-Type: multipart/mixed; boundary=outer\r\n')
        nfd_path = paths[3].with_name(paths[3].name.replace('Source', 'Source cafe\u0301'))
        paths[3].rename(nfd_path)
        paths[3] = nfd_path
        source_alias = root / 'InputAlias'
        source_alias.symlink_to(source, target_is_directory=True)
        report = root / 'input-report.jsonl'
        report.write_text(json.dumps({'output': unicodedata.normalize('NFC', str(source_alias / paths[3].relative_to(source))), 'source': '/synthetic/4.emlx',
                                      'account': 'priority', 'status': 'exported'}) + '\n')
        snapshot = {path: path.read_bytes() for path in paths}
        for path in paths:
            path.chmod(0o400)
        for directory in sorted(source.rglob('*'), reverse=True):
            if directory.is_dir():
                directory.chmod(0o500)
        source.chmod(0o500)
        try:
            result = run(source, output, root / 'control', '--input-report', str(report),
                         '--priority-account', 'priority', '--workers', '1')
            assert result.returncode == 0, (result.stdout, result.stderr)
            rows = [json.loads(line) for line in (output / 'export-report.jsonl').read_text().splitlines()]
            assert len(rows) == 6 and all(row['status'] == 'exported' for row in rows), rows
            assert rows[0]['account'] == 'priority' and rows[0]['original_source'] == '/synthetic/4.emlx'
            assert {row['id'] for row in rows} == {f'{i:08d}' for i in range(1, 7)}
            by_id = {row['id']: row for row in rows}
            documents = {key: Path(row['output']).read_text() for key, row in by_id.items()}
            assert 'Hello é friend' in documents['00000001']
            assert Path(by_id['00000001']['output']).name == '2024-03-18 - Plain_subject__00000001.md'
            assert '# Invoice' in documents['00000002'] and '[the site](https://example.test/a)' in documents['00000002']
            assert 'BAD SCRIPT' not in documents['00000002']
            assert 'Preferred plain' in documents['00000003'] and 'Unwanted HTML' not in documents['00000003']
            assert 'INNER MUST STAY ATTACHED' not in documents['00000004']
            related_row = by_id['00000004']
            attachments = related_row['attachments']
            assert len(attachments) == 5, attachments
            for index, attachment in enumerate(attachments, 1):
                target = Path(attachment['output'])
                assert target.name.startswith(Path(related_row['output']).stem + f'_att_{index:02d}_')
            assert [Path(a['output']).read_bytes() for a in attachments] == [binary, binary, binary, b'PDF bytes', raw_attached]
            assert attachments[3]['original_name'] == 'café.pdf'
            assert attachments[1]['original_name'] == '../../same.bin'
            assert '![' in documents['00000004'] and 'cid:logo' not in documents['00000004']
            assert documents['00000006'].index('First body') < documents['00000006'].index('Second body')
            assert by_id['00000006']['attachments'][0]['output'].endswith('.pdf')
            assert full_subject in documents['00000005'] and by_id['00000005']['subject'] == full_subject
            assert by_id['00000005']['attachments'][0]['original_name'] == long_name
            assert long_name.replace('\x7f', '')[:30] in documents['00000005']
            for path in output.rglob('*'):
                assert stat.S_IMODE(path.stat().st_mode) == (0o700 if path.is_dir() else 0o600), path
                for form in ('NFC', 'NFD'):
                    assert len(unicodedata.normalize(form, path.name).encode()) <= 255, path
                assert not any(ord(char) < 32 or ord(char) == 127 for char in path.name)
                assert not path.name.endswith((' ', '.'))
            for key, document in documents.items():
                for target in re.findall(r'!?\[[^\]]*\]\(([^)]+)\)', document):
                    if '://' not in target:
                        assert (Path(by_id[key]['output']).parent / unquote(target)).is_file(), target
            summary = json.loads((output / 'summary.json').read_text())
            state = json.loads((root / 'control/state.json').read_text())
            assert summary['status'] == state['status'] == 'completed'
            assert summary['exported'] == 6 and summary['failed'] == 0 and summary['workers'] == 1
            assert {path: path.read_bytes() for path in paths} == snapshot
            original_output = {str(p): p.read_bytes() for p in output.rglob('*') if p.is_file()}
            result = run(source, output, root / 'repeat-control')
            assert result.returncode != 0 and 'output_exists' in result.stderr, result.stderr
            assert {str(p): p.read_bytes() for p in output.rglob('*') if p.is_file()} == original_output
            for name, bad_output, bad_control in [('input', source / 'nested', root / 'bad-control'),
                                                   ('control', root / 'bad-output', source / 'control')]:
                result = run(source, bad_output, bad_control)
                assert result.returncode != 0 and 'unsafe_output' in result.stderr, (name, result.stderr)
                assert not bad_output.exists() and not bad_control.exists()
            for workers in ('0', '-1'):
                result = run(source, root / 'bad-workers', root / 'bad-workers-control', '--workers', workers)
                assert result.returncode != 0 and '--workers' in result.stderr
            result = run(source, root / 'more-workers', root / 'more-workers-control', '--workers', '9')
            assert result.returncode == 0, result.stderr
        finally:
            source.chmod(0o700)
            for path in source.rglob('*'):
                path.chmod(0o700 if path.is_dir() else 0o600)

        # Invalid encoding is a per-message failure; a subsequent healthy message survives.
        failure_source = root / 'failure-source'
        failure_source.mkdir()
        (failure_source / 'Undated - Bad__00000001.eml').write_bytes(
            b'Subject: Bad\r\nContent-Type: multipart/mixed; boundary=x\r\n\r\n'
            b'--x\r\nContent-Type: text/plain\r\n\r\nbody\r\n--x\r\n'
            b'Content-Type: application/pdf\r\nContent-Transfer-Encoding: base64\r\n\r\n!!!\r\n--x--\r\n')
        (failure_source / 'Undated - Good__00000002.eml').write_bytes(b'Subject: Good\r\n\r\nhealthy\r\n')
        failure_output = root / 'FailureOutput'
        result = run(failure_source, failure_output, root / 'failure-control', '--workers', '1')
        assert result.returncode == 1, (result.stdout, result.stderr)
        rows = [json.loads(line) for line in (failure_output / 'export-report.jsonl').read_text().splitlines()]
        assert rows[0]['status'] == 'failed' and rows[0]['reason'] == 'decode_error', rows
        assert rows[1]['status'] == 'exported' and 'healthy' in Path(rows[1]['output']).read_text()
        assert len(list(failure_output.rglob('*.md'))) == 1
        assert not list(failure_output.rglob('*_att_*'))
        assert not list(failure_output.rglob('*.tmp'))

        # A collision after publishing the first attachment cleans only that
        # message's new file, preserving the earlier exported message's files.
        collision_source = root / 'collision-source'
        collision_source.mkdir()
        for source_name, first_name, first_bytes in [('A', 'first-A.pdf', b'A'), ('B', 'first-B.pdf', b'B')]:
            payload = (b'Subject: Collision\r\nContent-Type: multipart/mixed; boundary=c\r\n\r\n'
                       b'--c\r\nContent-Type: text/plain\r\n\r\nbody\r\n--c\r\n'
                       b'Content-Type: application/pdf\r\nContent-Disposition: attachment; filename="'
                       + first_name.encode() + b'"\r\n\r\n' + first_bytes + b'\r\n--c\r\n'
                       b'Content-Type: application/pdf\r\nContent-Disposition: attachment; filename="shared.pdf"\r\n\r\n'
                       b'SHARED\r\n--c--\r\n')
            (collision_source / f'Undated - {source_name}__00000001.eml').write_bytes(payload)
        (collision_source / 'Undated - Z__00000002.eml').write_bytes(b'Subject: Later\r\n\r\nstill healthy\r\n')
        collision_output = root / 'CollisionOutput'
        result = run(collision_source, collision_output, root / 'collision-control', '--workers', '1')
        assert result.returncode == 1, (result.stdout, result.stderr)
        rows = [json.loads(line) for line in (collision_output / 'export-report.jsonl').read_text().splitlines()]
        assert [row['status'] for row in rows] == ['exported', 'failed', 'exported'], rows
        assert rows[1]['reason'] == 'output_exists', rows
        assert not list(collision_output.rglob('*first-B*'))
        assert next(collision_output.rglob('*first-A*')).read_bytes() == b'A'
        assert next(collision_output.rglob('*shared.pdf')).read_bytes() == b'SHARED'
        assert len(list(collision_output.rglob('*.md'))) == 2
        assert not list(collision_output.rglob('*.tmp'))

        # AFP exports cannot hard-link files. Exercise the production CLI with
        # that operation unavailable, then fail promotion after reserving a name.
        shim = root / 'publication-shim'
        shim.mkdir()
        (shim / 'sitecustomize.py').write_text(
            'import errno, os\n'
            'from pathlib import Path\n'
            'def unsupported_link(*args, **kwargs):\n'
            '    raise OSError(errno.ENOTSUP, "injected_hard_link_unsupported")\n'
            'os.link = unsupported_link\n'
            'original_replace = os.replace\n'
            'def replace(source, target, *args, **kwargs):\n'
            '    if Path(source).name.startswith(".markdown-") and ("Publish failure" in Path(target).name or ("Cleanup failure" in Path(target).name and "_att_02_" in Path(target).name)):\n'
            '        raise OSError(errno.ENOSPC, "injected_no_space")\n'
            '    return original_replace(source, target, *args, **kwargs)\n'
            'os.replace = replace\n'
            'original_unlink = os.unlink\n'
            'def unlink(path, *args, **kwargs):\n'
            '    if "Cleanup failure" in Path(path).name and "_att_01_" in Path(path).name:\n'
            '        raise PermissionError(errno.EACCES, "injected_cleanup_denied")\n'
            '    return original_unlink(path, *args, **kwargs)\n'
            'os.unlink = unlink\n')
        environment = dict(os.environ, PYTHONPATH=str(shim))
        portable_source = root / 'portable-source'
        portable_source.mkdir()
        (portable_source / 'Undated - Healthy__00000001.eml').write_bytes(b'Subject: Healthy\r\n\r\nportable bytes\r\n')
        portable_output = root / 'PortableOutput'
        result = run(portable_source, portable_output, root / 'portable-control', environment=environment)
        assert result.returncode == 0, (result.stdout, result.stderr)
        assert next(portable_output.glob('*.md')).read_text().endswith('portable bytes\n')
        (portable_source / 'Undated - Bad__00000000.eml').write_bytes(b'Subject: Publish failure\r\n\r\nfail promotion\r\n')
        failed_publication = root / 'FailedPublication'
        result = run(portable_source, failed_publication, root / 'failed-publication-control',
                     '--workers', '1', environment=environment)
        assert result.returncode == 1, (result.stdout, result.stderr)
        rows = [json.loads(line) for line in (failed_publication / 'export-report.jsonl').read_text().splitlines()]
        assert rows[0]['status'] == 'failed' and rows[0]['reason'] == 'write_error', rows
        assert 'injected_no_space' in rows[0]['detail'], rows
        assert rows[1]['status'] == 'exported', rows
        assert len(list(failed_publication.glob('*.md'))) == 1
        assert not list(failed_publication.rglob('*Publish failure*'))
        assert not list(failed_publication.rglob('*.tmp'))
        cleanup_source = root / 'cleanup-source'
        cleanup_source.mkdir()
        (cleanup_source / 'Undated - A__00000001.eml').write_bytes(
            b'Subject: Cleanup failure\r\nContent-Type: multipart/mixed; boundary=c\r\n\r\n'
            b'--c\r\nContent-Type: application/pdf\r\nContent-Disposition: attachment; filename="one.pdf"\r\n\r\nONE\r\n'
            b'--c\r\nContent-Type: application/pdf\r\nContent-Disposition: attachment; filename="two.pdf"\r\n\r\nTWO\r\n--c--\r\n')
        (cleanup_source / 'Undated - Z__00000002.eml').write_bytes(b'Subject: Later cleanup\r\n\r\nstill continues\r\n')
        cleanup_output = root / 'CleanupOutput'
        result = run(cleanup_source, cleanup_output, root / 'cleanup-control', '--workers', '1', environment=environment)
        assert result.returncode == 1 and (cleanup_output / 'summary.json').is_file(), (result.stdout, result.stderr)
        rows = [json.loads(line) for line in (cleanup_output / 'export-report.jsonl').read_text().splitlines()]
        assert rows[0]['status'] == 'failed' and rows[0]['reason'] == 'write_error', rows
        assert 'injected_no_space' in rows[0]['detail'], rows
        assert 'injected_cleanup_denied' in str(rows[0]['cleanup_errors']), rows
        assert rows[1]['status'] == 'exported', rows
        assert not list(cleanup_output.glob('*.tmp'))

        digest_bytes = b'From: digest@example.test\r\nSubject: Inner digest\r\n\r\nDIGEST BODY STAYS ATTACHED\r\n'
        budget_subject = 's' * 1000
        review_cases = [
            ('headerless', b'Subject: Headerless\r\nContent-Type: multipart/mixed; boundary=h\r\n\r\n'
             b'--h\r\n\r\nHeaderless body\r\n--h\r\n\r\n--h\r\nContent-Type: text/plain\r\n\r\n--h--\r\n',
             'Headerless body', None, None),
            ('digest', b'Subject: Digest\r\nContent-Type: multipart/digest; boundary=d\r\n\r\n--d\r\n\r\n'
             + digest_bytes + b'\r\n--d--\r\n', '', digest_bytes, None),
            ('related-filename', b'Subject: Related filename\r\nContent-Type: multipart/related; boundary=r; start="<root>"\r\n\r\n'
             b'--r\r\nContent-Type: text/html; name="index.html"\r\nContent-Disposition: inline; filename="index.html"\r\n'
             b'Content-ID: <root>\r\n\r\n<p>Selected related body</p>\r\n--r--\r\n',
             'Selected related body', None, None),
            ('qp-terminal', b'Subject: Truncated QP\r\nContent-Type: text/plain\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nLOST=',
             None, None, 'decode_error'),
            ('alternative-cid', b'Subject: Alternative CID\r\nContent-Type: multipart/alternative; boundary=a\r\n\r\n'
             b'--a\r\nContent-Type: text/plain\r\nContent-ID: <plain>\r\n\r\nSelected alternative body\r\n'
             b'--a\r\nContent-Type: text/html\r\nContent-ID: <html>\r\n\r\n<p>Other alternative body</p>\r\n--a--\r\n',
             'Selected alternative body', None, None),
            ('filename-budget', ('Subject: ' + budget_subject + '\r\nContent-Type: multipart/mixed; boundary=b\r\n\r\n').encode()
             + b'--b\r\nContent-Type: text/plain\r\n\r\nBudget body\r\n--b\r\nContent-Type: application/pdf\r\n'
             b'Content-Disposition: attachment; filename*=utf-8\'\'%C3%A9.pdf\r\n\r\nPDF\r\n--b--\r\n',
             'Budget body', b'PDF', None),
        ]
        review_failures = []
        for name, payload, expected_text, expected_attachment, expected_error in review_cases:
            case_source = root / ('review-' + name)
            case_source.mkdir()
            (case_source / 'Undated - Case__00000001.eml').write_bytes(payload)
            case_output = root / ('review-output-' + name)
            result = run(case_source, case_output, root / ('review-control-' + name), '--workers', '1')
            try:
                rows = [json.loads(line) for line in (case_output / 'export-report.jsonl').read_text().splitlines()]
                assert len(rows) == 1, rows
                row = rows[0]
                if expected_error:
                    assert result.returncode == 1 and row['status'] == 'failed' and row['reason'] == expected_error, rows
                    assert not list(case_output.glob('*.md'))
                else:
                    assert result.returncode == 0 and row['status'] == 'exported', rows
                    document = Path(row['output']).read_text()
                    assert expected_text in document, document
                    if expected_attachment is not None:
                        assert len(row['attachments']) == 1, row
                        attachment = Path(row['attachments'][0]['output'])
                        assert attachment.read_bytes() == expected_attachment
                        assert attachment.name.endswith('.eml' if name == 'digest' else 'é.pdf')
                        assert len(unicodedata.normalize('NFD', attachment.name).encode()) <= 255
                        if name == 'digest':
                            assert 'DIGEST BODY STAYS ATTACHED' not in document
                    else:
                        assert not row['attachments'], row
                    if name == 'alternative-cid':
                        assert 'Other alternative body' not in document
            except AssertionError as error:
                review_failures.append(f'{name}: {error}')
        assert not review_failures, '\n'.join(review_failures)
        spec = importlib.util.spec_from_file_location('markdown_runner', RUNNER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        parent = root / 'cache-parent'
        parent.mkdir()
        resolutions = []
        original_resolve = Path.resolve

        def counted_resolve(path, *args, **kwargs):
            resolutions.append(str(path))
            return original_resolve(path, *args, **kwargs)

        with patch.object(Path, 'resolve', counted_resolve):
            for number in range(100):
                module.path_key(parent / f'{number}.eml')
        assert resolutions == [str(parent)], resolutions

    print('Markdown acceptance passed: MIME, exact attachment bytes, safe names, local links, metadata priority, read-only input, failure isolation and new roots.')


if __name__ == '__main__':
    main()
