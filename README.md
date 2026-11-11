<p align="center">
  <img src="assets/icon.png" width="128" alt="apple-mail-exporter">
  <h1 align="center">apple-mail-exporter</h1>
  <p align="center">Search and export emails from Apple Mail's local database</p>
</p>

<p align="center">
  <a href="https://github.com/Aayush9029/apple-mail-exporter/releases/latest"><img src="https://img.shields.io/github/v/release/Aayush9029/apple-mail-exporter" alt="Release"></a>
  <a href="https://github.com/Aayush9029/apple-mail-exporter/blob/main/LICENSE"><img src="https://img.shields.io/github/license/Aayush9029/apple-mail-exporter" alt="License"></a>
</p>

## Install

```bash
brew install aayush9029/tap/apple-mail-exporter
```

Or tap first:

```bash
brew tap aayush9029/tap
brew install apple-mail-exporter
```

Requires Full Disk Access (System Settings > Privacy & Security > Full Disk Access).

## Export an entire account as EML

The account export in this fork reads Apple Mail's local files directly. It does not use a keyword filter or ask Mail to export each message.

Build and install this version; the upstream Homebrew package does not include account EML export:

```bash
swift build -c release
mkdir -p ~/.local/bin
install -m 755 .build/release/apple-mail-exporter ~/.local/bin/apple-mail-exporter
```

Run these commands from the terminal application that has Full Disk Access:

```bash
~/.local/bin/apple-mail-exporter --list-accounts
~/.local/bin/apple-mail-exporter --account "Work" --output ~/MailExport
```

Use an exact account name or account ID from the listing. An offline account folder can also be exported directly, without Mail automation:

```bash
~/.local/bin/apple-mail-exporter --account-dir "/path/to/Mail/V10/account-UUID" --output ~/MailExport
```

Every local `.emlx` and `.partial.emlx` message in the selected account is processed, including Sent, Archive, Junk, Trash and nested mailboxes. The destination contains an account-name folder, an account-ID subfolder when different, and the original storage-relative folder hierarchy. Accounts sharing a display name remain separate. Each source gets its own `.eml`; repeated message numbers in different folders cannot overwrite each other. Distinct source files are retained without deduplication. Files in detached `Attachments` directories are integrated into their parent messages rather than exported as additional messages.

Complete messages retain their original payload bytes and headers. Detached attachments and inline images are reconstructed from the matching local attachment files. A message with an unavailable attachment, invalid framing or other conversion failure is reported rather than counted as a complete EML. Other messages continue exporting. This exports data already on disk; it does not download missing server messages or attachments.

Progress and totals appear in the terminal. `export-report.jsonl` records every processed source, destination, result and structured failure reason; directory scan errors are also recorded. The exit status is nonzero if any message or subtree could not be exported. A repeat run compares EML contents, leaves identical files unchanged and replaces the report with the current run's results. Source Mail data is read-only; choose an output directory outside the source mail store.

## Readable date and subject folders

For a fresh export organized as `YYYY/MM/YYYY-MM-DD - Subject__ID.eml`, use the readable runner. It scans all local messages directly, without Mail automation or account-name selection. The output directory must be new. Subjects are decoded and made safe for filenames; unique IDs keep repeated subjects separate. Messages without a usable Date header go under `Undated`. The report retains each original account, mailbox path and message ID.

```bash
mkdir -p .build
swiftc -O -swift-version 6 -parse-as-library Sources/AppleMailExporter/EMLConverter.swift scripts/EMLConversionWorker.swift -o .build/apple-mail-conversion-worker
python3 scripts/export_readable.py --output /path/to/new/MailExport-Readable --control /tmp/new-mail-export-run --worker .build/apple-mail-conversion-worker
```

The runner uses eight persistent native conversion workers. Add `--priority-account UUID` to process a particular account first. `export-report.jsonl` and `summary.json` are copied to the export directory after the run; progress and the working report are available in the control directory during conversion. Missing source attachments are reported explicitly, and all other messages continue. Native-worker failures leave queued work available to surviving workers rather than marking healthy messages corrupt.

## Checks

```bash
swift test
swift build
python3 tests/cli_acceptance.py .build/debug/apple-mail-exporter
swift build -c release
python3 tests/cli_acceptance.py .build/release/apple-mail-exporter
python3 tests/scale_acceptance.py .build/release/apple-mail-exporter
python3 tests/readable_acceptance.py .build/apple-mail-conversion-worker
```

## Usage

```bash
apple-mail-exporter                                    # interactive mode
apple-mail-exporter airbnb --output receipts           # search + export
apple-mail-exporter receipt invoice payment --list-only # list matches only
apple-mail-exporter airbnb --limit 10                  # limit results
apple-mail-exporter -o ~/exports -l 50 "newsletter"    # custom output dir
```

## License

MIT
