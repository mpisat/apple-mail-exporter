import ArgumentParser
import AppleMailExporter
import Foundation

@main
struct AppleMailExporterCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apple-mail-exporter",
        abstract: "Search and export emails from Apple Mail's local database.",
        discussion: "Run with no arguments for interactive mode.",
        version: appVersion
    )

    @Argument(help: "Keywords to search (subject, sender address, sender name).")
    var keywords: [String] = []

    @Option(name: [.short, .long], help: "Output directory (default: output).")
    var output: String = "output"

    @Option(name: [.short, .long], help: "Max number of emails to export (0 = all).")
    var limit: Int = 0

    @Flag(name: .long, help: "Just list matching emails without exporting.")
    var listOnly: Bool = false

    @Flag(name: [.short, .customLong("interactive")], help: "Run in interactive mode.")
    var interactiveMode: Bool = false

    @Option(name: .customLong("mail-dir"), help: "Override the Mail V* directory.")
    var mailDir: String?

    @Option(name: .customLong("mail-base"), help: "Override the Mail base directory.")
    var mailBase: String?

    @Flag(name: .customLong("list-accounts"), help: "List Apple Mail account names, IDs and local directories.")
    var listAccounts = false

    @Option(name: .long, help: "Export every locally stored message of this account name or ID as EML.")
    var account: String?

    @Option(name: .customLong("account-dir"), help: "Export an offline account directory directly as EML.")
    var accountDir: String?

    func validate() throws {
        if listAccounts || account != nil || accountDir != nil {
            guard keywords.isEmpty, limit == 0, !listOnly, !interactiveMode else {
                throw ValidationError("Account EML export does not accept keyword filters, result limits, --list-only or --interactive.")
            }
            guard !listAccounts || (account == nil && accountDir == nil) else {
                throw ValidationError("Use --list-accounts separately from an account export.")
            }
            guard account == nil || accountDir == nil else {
                throw ValidationError("--account and --account-dir are alternative account selectors; use one.")
            }
            guard mailDir == nil, mailBase == nil else {
                throw ValidationError("For account EML export use --account-dir to select an offline account directory.")
            }
            guard account?.isEmpty != true, accountDir?.isEmpty != true else {
                throw ValidationError("Account names and paths must not be empty.")
            }
        }
    }

    func run() throws {
        if listAccounts {
            let accounts = try discoverMailAccounts()
            for account in accounts {
                print("\(account.name)\t\(account.id)\t\(account.directory.path)")
            }
            print("\(accounts.count) accounts")
            return
        }
        if account != nil || accountDir != nil {
            let selected: MailAccount
            if let accountDir {
                let path = URL(fileURLWithPath: (accountDir as NSString).expandingTildeInPath).standardizedFileURL
                selected = MailAccount(id: path.lastPathComponent, name: path.lastPathComponent, directory: path)
            } else if let account {
                selected = try selectMailAccount(named: account, accounts: discoverMailAccounts())
            } else { return }
            let outputURL = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
            print("Exporting every locally stored message from \(selected.name) as EML...")
            let result = try exportAccount(selected, output: outputURL) { progress in
                print("\(progress.found) found; \(progress.exported) exported; \(progress.unchanged) unchanged; \(progress.failed) failed; \(progress.scanErrors) scan errors")
            }
            print("Report: \(result.reportURL.path)")
            if result.failed > 0 || result.scanErrors > 0 { throw ExitCode.failure }
            return
        }
        let mailDirURL = mailDir.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let mailBaseURL = mailBase.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }

        if interactiveMode || keywords.isEmpty {
            runInteractive(mailDir: mailDirURL, mailBase: mailBaseURL)
            return
        }

        let results = try listMatches(
            keywords: keywords, limit: limit,
            mailDir: mailDirURL, mailBase: mailBaseURL
        )

        print("\nSearching for: \(keywords.joined(separator: ", "))")
        print("Found \(results.count) matching emails.\n")

        guard !results.isEmpty else { return }

        if listOnly {
            printEmailList(results)
            return
        }

        let exported = try runExport(
            keywords: keywords, output: output, limit: limit,
            mailDir: mailDirURL, mailBase: mailBaseURL
        )

        for path in exported {
            let name = path.lastPathComponent
            let parts = name.split(separator: "_", maxSplits: 2)
            let date = parts.count > 1 ? String(parts[1]) : ""
            print("  [\(date)] \(name)")
        }

        let outputPath = (output as NSString).expandingTildeInPath
        print("\nExported \(exported.count) emails to \(outputPath)\n")
    }
}

func printEmailList(_ results: [EmailRecord]) {
    for (i, msg) in results.enumerated() {
        let date = String(normalizeTimestamp(msg.dateSentRaw).prefix(10))
        let sender = msg.senderName ?? msg.senderAddress ?? "?"
        let subject = msg.subject ?? "?"
        print("  \(String(format: "%3d", i + 1)). [\(date)] \(sender): \(subject)")
    }
}

func printPreview(_ results: [EmailRecord], limit: Int = 10) {
    let previewCount = min(limit, results.count)
    for (i, msg) in results.prefix(previewCount).enumerated() {
        let date = String(normalizeTimestamp(msg.dateSentRaw).prefix(10))
        let sender = msg.senderName ?? msg.senderAddress ?? "?"
        let subject = String((msg.subject ?? "?").prefix(65))
        print("  \(String(format: "%3d", i + 1)). [\(date)] \(sender): \(subject)")
    }
    if results.count > previewCount {
        print("  ... and \(results.count - previewCount) more")
    }
}
