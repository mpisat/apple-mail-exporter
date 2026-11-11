import Foundation

public struct MailAccount {
    public let id: String
    public let name: String
    public let directory: URL

    public init(id: String, name: String, directory: URL) {
        self.id = id
        self.name = name
        self.directory = directory
    }
}

public enum AccountExportError: LocalizedError, Equatable {
    case unknownAccount(String)
    case ambiguousAccount(String)
    case metadataUnavailable(String)
    case sourceUnavailable(String)
    case unsafeOutput(String)

    public var reasonCode: String {
        switch self {
        case .unknownAccount: "unknown_account"
        case .ambiguousAccount: "ambiguous_account"
        case .metadataUnavailable: "account_metadata_unavailable"
        case .sourceUnavailable: "source_unavailable"
        case .unsafeOutput: "unsafe_output"
        }
    }

    public var errorDescription: String? {
        let detail: String
        switch self {
        case .unknownAccount(let name): detail = "No account named '\(name)'. Use --list-accounts."
        case .ambiguousAccount(let name): detail = "Multiple accounts match '\(name)'. Select the account ID shown by --list-accounts."
        case .metadataUnavailable(let message): detail = "Cannot read Mail account metadata: \(message). You can also use --account-dir with an account's local folder."
        case .sourceUnavailable(let path): detail = "Cannot read account directory: \(path). Check Full Disk Access for the application running this command."
        case .unsafeOutput(let path): detail = "Unsafe output location: \(path). Choose a separate destination outside the source mail store."
        }
        return "\(reasonCode): \(detail)"
    }
}

public func selectMailAccount(named name: String, accounts: [MailAccount]) throws -> MailAccount {
    let matches = accounts.filter { $0.name == name || $0.id == name }
    guard !matches.isEmpty else { throw AccountExportError.unknownAccount(name) }
    guard matches.count == 1 else { throw AccountExportError.ambiguousAccount(name) }
    return matches[0]
}

/// Uses Mail only for account metadata, never for enumerating or exporting messages.
public func discoverMailAccounts() throws -> [MailAccount] {
    let source = """
        tell application "Mail"
            set rows to {}
            repeat with a in every account
                set accountName to name of a
                set accountID to id of a
                set accountPath to POSIX path of (account directory of a)
                set end of rows to {accountName, accountID, accountPath}
            end repeat
            return rows
        end tell
        """
    guard let script = NSAppleScript(source: source) else {
        throw AccountExportError.metadataUnavailable("Cannot compile account query")
    }
    var error: NSDictionary?
    let result = script.executeAndReturnError(&error)
    if let error {
        throw AccountExportError.metadataUnavailable(error[NSAppleScript.errorMessage] as? String ?? error.description)
    }
    var accounts: [MailAccount] = []
    for index in 0..<result.numberOfItems {
        guard let row = result.atIndex(index + 1),
              let name = row.atIndex(1)?.stringValue,
              let id = row.atIndex(2)?.stringValue,
              let path = row.atIndex(3)?.stringValue, !path.isEmpty else {
            throw AccountExportError.metadataUnavailable("Mail returned an account without a directory")
        }
        accounts.append(MailAccount(id: id, name: name, directory: URL(fileURLWithPath: path)))
    }
    return accounts
}

public struct AccountExportSummary {
    public internal(set) var found = 0
    public internal(set) var exported = 0
    public internal(set) var unchanged = 0
    public internal(set) var failed = 0
    public internal(set) var scanErrors = 0
    public let reportURL: URL
}

private struct ExportReportEntry: Encodable {
    let account: String
    let accountID: String
    let source: String
    let output: String?
    let status: String
    let reason: String?
    let detail: String?
}

private func isWithin(_ url: URL, root: URL) -> Bool {
    url.path == root.path || url.path.hasPrefix(root.path + "/")
}

private func accountFolderName(_ name: String) -> String {
    // Reversible encoding avoids collisions between names such as A/B and A_B.
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_@ ")
    return name.addingPercentEncoding(withAllowedCharacters: allowed) ?? "account"
}

/// A single traversal, with memory bounded by the largest current message and directory set.
public func exportAccount(
    _ account: MailAccount, output: URL,
    progress: ((AccountExportSummary) -> Void)? = nil
) throws -> AccountExportSummary {
    let fm = FileManager.default
    let sourceRoot = account.directory.standardizedFileURL.resolvingSymlinksInPath()
    do {
        let values = try sourceRoot.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey])
        guard values.isDirectory == true, values.isReadable == true else {
            throw AccountExportError.sourceUnavailable(sourceRoot.path)
        }
        // Force a real directory read: permission failures must not look like empty mailboxes.
        _ = try fm.contentsOfDirectory(at: sourceRoot, includingPropertiesForKeys: nil)
    } catch {
        throw AccountExportError.sourceUnavailable(sourceRoot.path)
    }
    let requestedOutput = output.standardizedFileURL.resolvingSymlinksInPath()
    var targetRoot = requestedOutput.appendingPathComponent(accountFolderName(account.name.isEmpty ? account.id : account.name))
    if account.id != account.name {
        targetRoot.appendPathComponent(accountFolderName(account.id))
    }
    targetRoot = targetRoot.standardizedFileURL.resolvingSymlinksInPath()
    var protectedRoots = [sourceRoot, fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mail").resolvingSymlinksInPath()]
    var ancestor = sourceRoot
    while ancestor.path != "/" {
        let component = ancestor.lastPathComponent
        if component.hasPrefix("V"), component.count > 1, component.dropFirst().allSatisfy(\.isNumber),
           ancestor.deletingLastPathComponent().lastPathComponent == "Mail" {
            protectedRoots.append(ancestor.deletingLastPathComponent())
            break
        }
        ancestor.deleteLastPathComponent()
    }
    for protectedRoot in protectedRoots {
        guard !isWithin(requestedOutput, root: protectedRoot), !isWithin(targetRoot, root: protectedRoot) else {
            throw AccountExportError.unsafeOutput(targetRoot.path)
        }
    }
    try fm.createDirectory(at: targetRoot, withIntermediateDirectories: true)
    let reportURL = targetRoot.appendingPathComponent("export-report.jsonl")
    if fm.fileExists(atPath: reportURL.path) {
        let values = try reportURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw AccountExportError.unsafeOutput(reportURL.path) }
    }
    // A report is replaced on each run; unchanged EMLs are still recorded in the new report.
    try Data().write(to: reportURL, options: .atomic)
    let report = try FileHandle(forWritingTo: reportURL)
    defer { try? report.close() }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var summary = AccountExportSummary(reportURL: reportURL)
    var reportError: Error?
    var createdDirectories: Set<String> = [targetRoot.path]

    func record(source: URL, output: URL?, status: String, reason: String? = nil, detail: String? = nil) throws {
        let entry = ExportReportEntry(
            account: account.name, accountID: account.id, source: source.path,
            output: output?.path, status: status, reason: reason, detail: detail
        )
        var line = try encoder.encode(entry)
        line.append(10)
        try report.write(contentsOf: line)
    }

    guard let enumerator = fm.enumerator(
        at: sourceRoot, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey], options: [],
        errorHandler: { url, error in
            summary.scanErrors += 1
            do { try record(source: url, output: nil, status: "failed", reason: "scan_error", detail: error.localizedDescription) }
            catch { reportError = error; return false }
            return true
        }
    ) else { throw AccountExportError.sourceUnavailable(sourceRoot.path) }

    for case let source as URL in enumerator {
        if let reportError { throw reportError }
        // Detached attachment files are MIME parts, even when one is itself named *.emlx.
        // Pruning them also avoids traversing every attachment during message discovery.
        if source.lastPathComponent == "Attachments" {
            enumerator.skipDescendants()
            continue
        }
        guard source.pathExtension.lowercased() == "emlx" else { continue }
        summary.found += 1
        var destination: URL?
        do {
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw AccountExportError.sourceUnavailable(source.path)
            }
            // FileManager can return /private/var paths for a /var root on macOS.
            let normalizedSource = source.standardizedFileURL.resolvingSymlinksInPath()
            guard isWithin(normalizedSource, root: sourceRoot) else {
                throw AccountExportError.sourceUnavailable(source.path)
            }
            let relative = normalizedSource.pathComponents.dropFirst(sourceRoot.pathComponents.count).joined(separator: "/")
            // Preserve storage-relative names as well as mailbox hierarchy so repeated IDs never collide.
            let result = targetRoot.appendingPathComponent(relative).deletingPathExtension().appendingPathExtension("eml")
            destination = result
            let resolved = result.resolvingSymlinksInPath()
            guard isWithin(resolved, root: targetRoot), !isWithin(resolved, root: sourceRoot), resolved == result else {
                throw AccountExportError.unsafeOutput(result.path)
            }
            let message = try convertEMLXToEML(at: source)
            if fm.fileExists(atPath: result.path), try Data(contentsOf: result, options: .mappedIfSafe) == message {
                try record(source: source, output: result, status: "unchanged")
                summary.unchanged += 1
            } else {
                let parent = result.deletingLastPathComponent()
                if !createdDirectories.contains(parent.path) {
                    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                    createdDirectories.insert(parent.path)
                }
                try message.write(to: result, options: .atomic)
                try record(source: source, output: result, status: "exported")
                summary.exported += 1
            }
        } catch {
            summary.failed += 1
            let reason: String
            if let conversion = error as? EMLConversionError { reason = conversion.reasonCode }
            else if let export = error as? AccountExportError { reason = export.reasonCode }
            else { reason = "io_error" }
            try record(source: source, output: destination, status: "failed", reason: reason, detail: error.localizedDescription)
        }
        if summary.found.isMultiple(of: 100) { progress?(summary) }
    }
    if let reportError { throw reportError }
    try report.synchronize()
    progress?(summary)
    return summary
}
