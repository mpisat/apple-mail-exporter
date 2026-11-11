#!/usr/bin/env python3
"""Local-only large-message-count acceptance check, using synthetic mail."""
import pathlib
import resource
import subprocess
import sys
import tempfile
import time


def payload(index):
    return (f"Message-ID: <{index}@example.test>\r\nSubject: Bulk {index}\r\n\r\n".encode()
            + b"synthetic body " * 64 + b"\r\n")


def main():
    binary = pathlib.Path(sys.argv[1]).resolve()
    count = 10000
    with tempfile.TemporaryDirectory(prefix="mail-export-scale-") as tmp:
        root = pathlib.Path(tmp)
        account = root / "Scale"
        for folder in range(20):
            (account / f"Folder{folder}.mbox" / "Messages").mkdir(parents=True)
        for index in range(count):
            message = payload(index)
            (account / f"Folder{index % 20}.mbox" / "Messages" / f"{index}.emlx").write_bytes(
                str(len(message)).encode() + b"\n" + message)
        output = root / "output"
        started = time.monotonic()
        result = subprocess.run([str(binary), "--account-dir", str(account), "--output", str(output)],
                                capture_output=True, timeout=120)
        elapsed = time.monotonic() - started
        assert result.returncode == 0, result.stderr.decode(errors="replace")
        files = list(output.rglob("*.eml"))
        assert len(files) == count, len(files)
        for path in files:
            assert path.read_bytes() == payload(int(path.stem)), path
        assert b"10000 found; 10000 exported; 0 unchanged; 0 failed; 0 scan errors" in result.stdout
        memory_mib = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss / (1024 * 1024)
        print(f"Scale acceptance passed: {count} EMLs independently verified; export {elapsed:.2f}s; child peak RSS {memory_mib:.1f} MiB on macOS")


if __name__ == "__main__":
    main()
