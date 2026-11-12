# Readable Markdown email export implementation plan

> **For agentic workers:** REQUIRED: Use subagent-driven-development to implement this plan. Steps use checkbox syntax for tracking.

**Goal:** Add a separate Synology Markdown export in the owner-approved date/subject/ID layout, with sanitized, individually numbered original attachment filenames.

**Architecture:** Read the existing complete readable EML export using Python standard-library MIME parsing. Preserve relative year/month folders and source IDs, render readable Markdown and extract decoded attachment bytes beside each message. Keep the existing EML export read-only. A new output directory and per-message report isolate failures and prevent overwrites.

**Tech Stack:** Python 3 standard library; existing Swift exporter remains unchanged.

## Chunk 1: Conversion and batch runner

### Task 1: Markdown export

**Files:** Create `scripts/export_markdown.py`; create `tests/markdown_acceptance.py`; modify `README.md` to document command and checks.

- [x] Write CLI acceptance fixtures first and observe failure because the new script is absent.
- [x] Implement input EML scanning, bounded thread workers, date/month layout preservation, Markdown headers and MIME body rendering. Prefer plain text in multipart/alternative; convert HTML-only bodies to readable Markdown. Decode declared charsets and transfer encodings. Preserve nested multipart body ordering; treat attached message/rfc822 as an attachment rather than injecting its body into the parent.
- [x] Extract explicit attachments and inline MIME resources as decoded bytes, including nameless files with a useful MIME-derived fallback extension. Use `EMAIL_STEM_att_01_SANITIZED_ORIGINAL.ext`; link all attachments from Markdown and resolve CID image references to their local files. Never fetch remote images or links.
- [x] Keep the date and unique ID intact. All files for one message share its final email stem. Fit actual filesystem 255-byte filename limits including Unicode decomposition by truncating names only as needed; retain full subjects and original attachment names in Markdown/report. Duplicate attachment names retain separate ordinal numbers. Handle reserved separators, controls, trailing spaces/dots and empty names.
- [x] Support new output/control directories, private file modes, per-item failure isolation, atomic individual writes with no overwrites, final JSONL report and summary, progress state and account priority when the input EML report is available. Do not silently count a decoding or write failure as success; clean only files created by the failed message.
- [x] Test plain/HTML-only, multipart alternatives and related images, nested messages, binary/quoted-printable/RFC2231 attachment names and content, traversal names, duplicates, long Unicode, nameless parts, failure followed by healthy mail, unsafe roots, no overwrites, read-only input and local links that resolve.
- [x] Run the new acceptance check and existing readable acceptance check. Update README with the command and exact behavior; review the diff.

Task 1 verification: `python3 tests/markdown_acceptance.py` first failed because `scripts/export_markdown.py` was absent, then passed after implementation. A related HTML root carrying a CID also failed before its classification fix and passed afterwards. `python3 tests/readable_acceptance.py /tmp/apple-mail-readable-worker-recovery` passed with the existing native worker. Fixtures include exact mixed-line-ending attached mail bytes, report NFC versus on-disk NFD, and an attachment-write collision that preserves the earlier message while removing the failed message's new file.

## Chunk 2: Delivery and live run

### Task 2: Review, integrate and run

- [ ] Obtain spec and code-quality reviews and resolve verified findings.
- [ ] Fetch and integrate into delivery branch `main`; run acceptance on the integrated tree; push and verify remote containment.
- [ ] Confirm Synology is mounted and the new Markdown destination is absent; launch the verified runner with the priority account from the private existing export report.
- [ ] Exercise real Markdown, follow local attachment links and compare extracted bytes against decoded source EML attachments. Report destination, active/completed status and explicit source conversion limitations.

Existing EML failures remain in their original report and are not mislabeled as Markdown successes. This addition converts the complete EML files already available, not unavailable server content. The owner has been told this input choice. Public documentation and fixtures contain no private account IDs, subjects or mount details.
