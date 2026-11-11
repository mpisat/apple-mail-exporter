#!/usr/bin/env python3
"""Exercise account export through the compiled production CLI."""
import email.policy
import json
import pathlib
import subprocess
import sys
import tempfile
from email.parser import BytesParser


def run(binary, *args):
    return subprocess.run([str(binary), *map(str, args)], capture_output=True, timeout=60)


def emlx(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(str(len(payload)).encode() + b"\n" + payload + b"\n<?xml version=\"1.0\"?><plist><dict/></plist>")


def main():
    binary = pathlib.Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix="mail-export-acceptance-") as tmp:
        root = pathlib.Path(tmp)
        account = root / "Work"
        messages = account / "INBOX.mbox" / "Data" / "0" / "Messages"
        original = b"From: sender@example.test\r\nTo: owner@example.test\r\nSubject: Plain\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nHello \xe2\x98\x83\r\n"
        emlx(messages / "1.emlx", original)
        emlx(account / "Sent.mbox" / "Messages" / "1.emlx", original.replace(b"Plain", b"Sent"))
        emlx(account / "Junk.mbox" / "Nested.mbox" / "Messages" / "2.emlx", original)
        emlx(account / "Trash.mbox" / "Messages" / "3.emlx", original)
        emlx(root / "Personal" / "Messages" / "999.emlx", original)
        attachment = b"\x00\x01\xffPDF test attachment\r\n"
        partial = (b"From: sender@example.test\r\nSubject: Attachment\r\nMIME-Version: 1.0\r\n"
                   b"Content-Type: multipart/mixed; boundary=outer\r\n\r\n"
                   b"--outer\r\nContent-Type: text/plain\r\n\r\nBody\r\n"
                   b"--outer\r\nContent-Type: application/octet-stream; name=file.bin\r\n"
                   b"Content-Disposition: attachment; filename=file.bin\r\n"
                   b"Content-Transfer-Encoding: base64\r\nX-Apple-Content-Length: 32\r\n\r\n\r\n--outer--\r\n")
        emlx(messages / "4.partial.emlx", partial)
        slot = messages.parent / "Attachments" / "4" / "2"
        slot.mkdir(parents=True)
        (slot / "file.bin").write_bytes(attachment)
        # An attached Apple Mail message is an attachment, not another stored message.
        emlx(messages.parent / "Attachments" / "777" / "2" / "attached.emlx", original)
        output = root / "export"
        result = run(binary, "--account-dir", account, "--output", output)
        assert result.returncode == 0, result.stderr.decode(errors="replace")
        files = list(output.rglob("*.eml"))
        assert len(files) == 5, [str(p) for p in files]
        assert not list(output.rglob("999.eml")), "cross-account leakage"
        plain = next(p for p in files if p.name == "1.eml" and "INBOX" in str(p))
        assert plain.read_bytes() == original, "complete EML bytes changed"
        attached = next(p for p in files if "4" in p.stem)
        parsed = BytesParser(policy=email.policy.default).parsebytes(attached.read_bytes())
        assert parsed["Subject"] == "Attachment"
        assert not parsed.defects, parsed.defects
        assert list(parsed.iter_attachments())[0].get_payload(decode=True) == attachment
        repeated = run(binary, "--account-dir", account, "--output", output)
        assert repeated.returncode == 0, repeated.stderr
        assert len(list(output.rglob("*.eml"))) == 5
        assert b"unchanged" in repeated.stdout.lower(), repeated.stdout
        # A bad message must not prevent unrelated later mail from exporting.
        emlx(messages / "5.partial.emlx", partial)
        emlx(messages / "6.emlx", original.replace(b"Plain", b"After failure"))
        emlx(messages / "7.partial.emlx", b"Content-Type:\r\nX-Apple-Content-Length: 0\r\n\r\n")
        broken = run(binary, "--account-dir", account, "--output", output)
        assert broken.returncode != 0, "incomplete export reported success"
        assert len(list(output.rglob("*.eml"))) == 6, "failed message exported or healthy mail skipped"
        reports = list(output.rglob("*.jsonl"))
        assert reports, "no per-message report"
        records = [json.loads(line) for line in reports[-1].read_text().splitlines()]
        failures = [r for r in records if r.get("status") == "failed"]
        assert len(failures) == 2, records
        assert {r["reason"] for r in failures} == {"missing_attachment", "malformed_mime"}, failures
        assert any("5.partial.emlx" in r["source"] and r["reason"] == "missing_attachment" for r in failures)
        unsafe = run(binary, "--account-dir", account, "--output", account / "export")
        assert unsafe.returncode != 0 and b"unsafe_output" in unsafe.stderr, unsafe.stderr
        unknown = run(binary, "--account-dir", root / "absent", "--output", root / "bad")
        assert unknown.returncode != 0 and b"source_unavailable" in unknown.stderr, unknown.stderr
        mixed = run(binary, "keyword", "--account-dir", account, "--output", output)
        assert mixed.returncode != 0 and b"keyword" in mixed.stderr.lower(), mixed.stderr
        conflicting = run(binary, "--account", "Other", "--account-dir", account, "--output", output)
        assert conflicting.returncode != 0 and b"alternative" in conflicting.stderr.lower(), conflicting.stderr
        empty = root / "Empty"
        empty.mkdir()
        empty_result = run(binary, "--account-dir", empty, "--output", root / "empty-export")
        assert empty_result.returncode == 0, empty_result.stderr
        assert b"0 found" in empty_result.stdout, empty_result.stdout
    print("CLI acceptance passed: complete EML, attachments, every folder, account isolation, repeat export, failure reporting, continued progress, unsafe paths and empty accounts")


if __name__ == "__main__":
    main()
