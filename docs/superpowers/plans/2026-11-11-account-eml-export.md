# Account EML Export Implementation Plan

> For agentic workers: use subagent-driven-development for the independent conversion task and review; follow test-driven-development and verification-before-completion.

**Goal:** Select an Apple Mail account by name and export every locally stored message as an individual EML, including locally available detached attachments, without keyword filtering or routing messages through another mail application.

**Architecture:** Extend the existing Swift package with an account EML path. Enumerate the selected account's files once instead of looking up each message through Envelope Index. Copy complete message payloads without text decoding; reconstruct detached MIME parts using their Apple part-number directories. Source files remain read-only. Keep existing keyword Markdown commands intact.

**Tech Stack:** Existing Swift 6 package, Foundation, ArgumentParser; no additional runtime or service.

## Chunk 1: Implementation and checks

### Task 1: Lossless message conversion

Files: create `Sources/AppleMailExporter/EMLConverter.swift` and `tests/AppleMailExporterTests/EMLConverterTests.swift`.

- [x] Add failing fixtures for exact byte preservation, UTF-8 byte lengths, binary bodies, nested MIME attachments and inline images, MIME header folding/case, absent attachments and malformed/truncated payloads.
- [x] Confirm failure before implementation with `swift test --filter EMLConverterTests`.
- [x] Implement `public func convertEMLXToEML(at source: URL) throws -> Data` and public typed conversion errors. Strip only the EMLX byte-count prefix and metadata epilogue. Rebuild parts marked `X-Apple-Content-Length` from the sibling `Attachments/<message-id>/<part-number>/` directory. Reject incomplete conversion explicitly. Never silently export an incomplete file as complete.
- [x] Re-run converter tests, then exercise a reference corpus from `qqilihq/partial-emlx-converter` locally. Preserve applicable MIT attribution for any adapted code or fixtures. No substantial upstream code or private fixtures were copied.

### Task 2: Account export and CLI

Files: create `Sources/AppleMailExporter/AccountExport.swift`, create `tests/AppleMailExporterTests/AccountExportTests.swift`, modify `Sources/CLI/CLI.swift` and `README.md`; add CLI acceptance checks.

- [x] Write failing CLI checks for account selection, no cross-account leakage, all folders, no keyword requirement, an empty account, complete EML bytes, missing attachment failures, continue-after-error and a repeat export.
- [x] Add `--list-accounts`, `--account NAME`, and `--account-dir PATH` (for offline stores). Resolve live account names and directory paths in one metadata-only Mail AppleScript call using the installed Mail scripting dictionary's `name`, `id`, and `account directory` properties; do not enumerate messages through AppleScript.
- [x] Traverse the account's local message tree once, preserving mailbox and storage-relative paths and collision-free source basenames. Include Trash, Junk, Archive, Sent and nested folders. Do not deduplicate distinct source files.
- [x] Write EML atomically, compare existing files for repeat runs, record per-message results in JSON Lines with exact source/output and structured failure reason, show progress and totals, and exit nonzero if any source cannot be exported completely. Continue on per-message and subtree enumeration errors and report them.
- [x] Reject ambiguous/unknown accounts and unsafe output locations, including output within the Mail source. Do not mutate Mail data, download mail or request Mail synchronization.
- [x] Run the complete Swift test suite and CLI fixture acceptance checks, build/install a release binary, then list real accounts if macOS permissions allow. The command runner cannot access Mail data or Mail automation; the user has Full Disk Access in iTerm and was given the installed binary's account listing/export commands. Actual account discovery and real mail export remain unverified.

### Task 3: Review and delivery

- [x] Obtain independent spec review, then code quality review; verify findings against source and fix with red/green checks.
- [x] Re-read the complete diff, integrate into the delivery `main` branch, re-run checks on that tree, and install the binary in the user's local bin directory.
- [x] Keep exported personal messages and reports outside git. Push only source to the owner's `mpisat/apple-mail-exporter` delivery fork, `main` branch.

## Acceptance evidence

Use native Mac tooling only. Checks are `swift test`, `swift build -c release`, and a production-CLI fixture harness that independently parses generated EML and asserts decoded attachment bytes. No Cloudflare usage, Docker, remote hosts, paid tools, message-count caps, keyword filters or account credentials.

Observed before integration: all 66 Swift tests passed; debug, release and installed-binary CLI acceptance passed. The optimized binary exported and independently byte-verified 10,000 synthetic messages in 15.94 seconds, with 89.7 MiB child peak RSS on this Mac. Public reference corpus conversion restored nine detached payloads across five messages; remaining corpus failures identify absent attachments or truncated EMLX files. Encoded lengths cannot prove same-length source integrity, and unknown quoted-printable encoder lengths are reported as unverified rather than guessed corrupt.

Verified review fixes cover conflicting account selectors, duplicate account names, full Mail-store output protection, macOS path aliases, attached EMLX files being misidentified as messages, empty MIME media types, digest defaults, base64 wrapping, exact Finder metadata exclusion and typed attachment metadata failures. Spec re-reviews and final bounded code quality review approved the corrected source.

Integrated `main` validation: all 66 tests passed; debug and optimized release CLI acceptance passed; all 10,000 synthetic EMLs passed independent byte comparisons, with export taking 9.08 seconds and 89.7 MiB peak child RSS. The installed `~/.local/bin/apple-mail-exporter` matches the integrated release binary. Implementation commit `2d76c081af468501e1bb8010ed69b8b3bbe9b3e5` was pushed to the owner's fork. Actual Mail account discovery and real archive export are still unverified because this command runner cannot access the user's Mail store or Mail automation; the user can exercise those paths from iTerm, which has Full Disk Access.

## Owner correction and readable export

The owner rejected Apple’s internal storage hierarchy, approved `YYYY/MM/YYYY-MM-DD - Subject__ID.eml`, identified a priority account, and explicitly requested a clean restart. The old export processes were stopped and verified absent. A fresh readable export started on the chosen mounted destination, prioritizing that account. No old exported files were reused in the clean run. Personal paths, account identifiers, inventory and progress remain in the private run records rather than this repository.

The readable runner retains original account, mailbox path and message ID in its audit report. Date headers determine year/month and filename dates; unusable dates are recorded under `Undated`. Decoded subjects receive filesystem-safe names and globally unique sequence suffixes. Eight persistent native workers perform conversion; audit and progress records remain local until final report copying. A dead worker cannot consume the remaining queue, and broken-pipe cleanup cannot prevent final accounting. A synthetic exit-17 worker reproduced that failure before the fix.

Real extraction exposed two cache metadata cases: LF-normalized text/calendar files retain CRLF wire lengths, and full attached RFC822 messages can exceed an earlier recorded size. Tests reproduced both failures before fixes. Text data remains byte-exact; only the exact canonical line-ending size alternative is accepted. A larger unencoded attached message requires complete header framing before a stale length is accepted, and original 7bit/8bit/binary encoding is preserved. Empty, undersized and header-only attached messages remain rejected. All 74 Swift tests passed after these corrections. Readable production-entrypoint tests cover priority, duplicate subjects, long Unicode names, containment, no overwrites, byte-exact calendar and attached-message data, missing attachments, and worker exit handling.

The readable run is in progress. Final coverage reconciliation and missing-attachment accounting remain required before claiming the real extraction complete. Some attachment files are absent from the local store; saving available portions as explicitly incomplete EMLs was offered and remains awaiting the owner's answer.
