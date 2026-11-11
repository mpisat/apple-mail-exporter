import Foundation
import Testing
@testable import AppleMailExporter

@Suite struct AccountExportTests {
    @Test func selectsExactAccountNameAndRejectsOthers() throws {
        let work = MailAccount(id: "work-id", name: "Work", directory: URL(fileURLWithPath: "/Mail/work"))
        let personal = MailAccount(id: "personal-id", name: "Personal", directory: URL(fileURLWithPath: "/Mail/personal"))
        #expect(try selectMailAccount(named: "Work", accounts: [work, personal]).id == "work-id")
        #expect(throws: AccountExportError.unknownAccount("Absent")) {
            try selectMailAccount(named: "Absent", accounts: [work, personal])
        }
        #expect(throws: AccountExportError.ambiguousAccount("Work")) {
            try selectMailAccount(named: "Work", accounts: [work, work])
        }
    }

    @Test func supportsAccountIDWithoutFuzzyNameMatching() throws {
        let account = MailAccount(id: "work-id", name: "Work", directory: URL(fileURLWithPath: "/Mail/work"))
        #expect(try selectMailAccount(named: "work-id", accounts: [account]).name == "Work")
        #expect(throws: AccountExportError.unknownAccount("Wor")) {
            try selectMailAccount(named: "Wor", accounts: [account])
        }
    }

    @Test func exportsNoMailOutsideSelectedRootAndPreservesRepeatedSourceNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent("Work")
        let original = Data("Subject: Test\r\n\r\nBody\r\n".utf8)
        for folder in ["Work/INBOX.mbox/Messages", "Work/Sent.mbox/Messages", "Personal/Messages"] {
            let directory = root.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var source = Data("\(original.count)\n".utf8)
            source.append(original)
            try source.write(to: directory.appendingPathComponent("1.emlx"))
        }
        let account = MailAccount(id: "Work", name: "Work", directory: work)
        let output = root.appendingPathComponent("output")
        let summary = try exportAccount(account, output: output)
        #expect(summary.found == 2)
        #expect(summary.exported == 2)
        #expect(summary.failed == 0)
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("Work/INBOX.mbox/Messages/1.eml").path))
        let repeated = try exportAccount(account, output: output)
        #expect(repeated.unchanged == 2)
        #expect(repeated.exported == 0)
        #expect(repeated.failed == 0)
    }

    @Test func refusesOutputInsideSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = MailAccount(id: "test", name: "test", directory: root)
        do {
            _ = try exportAccount(account, output: root.appendingPathComponent("export"))
            Issue.record("Unsafe output was accepted")
        } catch let error as AccountExportError {
            #expect(error.reasonCode == "unsafe_output")
        }
    }

    @Test func identicalAccountNamesHaveSeparateOutputNamespaces() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("output")
        for id in ["first", "second"] {
            let directory = root.appendingPathComponent(id).appendingPathComponent("Messages")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let payload = Data("Subject: \(id)\n\nbody".utf8)
            try (Data("\(payload.count)\n".utf8) + payload).write(to: directory.appendingPathComponent("1.emlx"))
            let account = MailAccount(id: id, name: "Work", directory: directory.deletingLastPathComponent())
            #expect(try exportAccount(account, output: output).exported == 1)
        }
        let files = FileManager.default.enumerator(at: output, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "eml" } ?? []
        #expect(files.count == 2)
        #expect(Set(try files.map { try String(contentsOf: $0, encoding: .utf8) }).count == 2)
    }

    @Test func rejectsOutputInAnotherAccountOfSameMailStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let mail = root.appendingPathComponent("Mail/V10")
        let accountRoot = mail.appendingPathComponent("first")
        let other = mail.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: accountRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = MailAccount(id: "first", name: "Work", directory: accountRoot)
        do {
            _ = try exportAccount(account, output: other)
            Issue.record("Output inside another account was accepted")
        } catch let error as AccountExportError {
            #expect(error.reasonCode == "unsafe_output")
        }
    }
}
