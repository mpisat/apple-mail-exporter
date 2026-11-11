import Foundation
import Testing
@testable import AppleMailExporter

@Suite struct EMLConverterTests {
    private func fixture(_ payload: Data, name: String = "42.partial.emlx", attachments: [String: Data] = [:], prefix: String? = nil) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("eml-converter-\(UUID().uuidString)")
        let messages = root.appendingPathComponent("Messages")
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
        let source = messages.appendingPathComponent(name)
        try (Data((prefix ?? "\(payload.count)\n").utf8) + payload + Data("\n<?xml version=\"1.0\"?><plist><dict/></plist>".utf8)).write(to: source)
        for (slot, bytes) in attachments {
            let file = root.appendingPathComponent("Attachments/42/\(slot)")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file)
        }
        return source
    }

    private func cleanup(_ source: URL) {
        try? FileManager.default.removeItem(at: source.deletingLastPathComponent().deletingLastPathComponent())
    }

    private func expectFailure(_ source: URL, _ reason: String) {
        do {
            _ = try convertEMLXToEML(at: source)
            Issue.record("Expected \(reason)")
        } catch let error as EMLConversionError {
            #expect(error.reasonCode == reason)
        } catch {
            Issue.record("Expected typed conversion error, got \(error)")
        }
    }

    @Test func preservesBinaryPayloadAndEveryHeaderExactly() throws {
        let payload = Data("X-Custom: retain\r\nSubject: caf".utf8) + Data([0xE9]) + Data("\r\nContent-Type: application/octet-stream\r\n\r\n".utf8) + Data([0, 0xFF, 0x80, 13, 10, 1])
        let source = try fixture(payload, name: "42.emlx", prefix: "\(payload.count)     \r\n")
        defer { cleanup(source) }
        #expect(try convertEMLXToEML(at: source) == payload)
    }

    @Test(arguments: ["no length\n", "-1\n", "999999999999999999999999999999\n", "12x\n"])
    func rejectsInvalidFraming(prefix: String) throws {
        let source = try fixture(Data("Subject: Test\n\nbody".utf8), prefix: prefix)
        defer { cleanup(source) }
        expectFailure(source, "malformed_emlx")
    }

    @Test func rejectsTruncatedPayload() throws {
        let source = try fixture(Data("Subject: Test\n\nbody".utf8), prefix: "99999\n")
        defer { cleanup(source) }
        expectFailure(source, "truncated_emlx")
    }

    @Test func missingMessageIsTypedFailure() {
        expectFailure(URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString).emlx"), "unreadable_message")
    }

    private func part(length: String = "4", extra: String = "", encoding: String = "base64") -> String {
        "Content-Type: application/octet-stream; name=blob.bin\r\nContent-Disposition: attachment; filename=blob.bin\r\nContent-Transfer-Encoding: \(encoding)\r\nX-Apple-Content-Length: \(length)\r\n\(extra)\r\n"
    }

    @Test func reconstructsBinaryAttachmentAndPreservesSurroundingBytes() throws {
        let before = "Subject: keep\r\nContent-Type: multipart/mixed; boundary=outer\r\n\r\npreamble\r\n--outer\r\nContent-Type: text/plain\r\n\r\nkeep this\r\n--outer\r\n"
        let after = "\r\n--outer--\r\nepilogue\r\n"
        let source = try fixture(Data((before + part() + after).utf8), attachments: ["2/blob.bin": Data([0, 0xFF, 0x80])])
        defer { cleanup(source) }
        let output = try convertEMLXToEML(at: source)
        let expected = before + part().replacingOccurrences(of: "X-Apple-Content-Length: 4\r\n", with: "") + "AP+A" + after
        #expect(output == Data(expected.utf8))
    }

    @Test func nestedMultipartAndRFC822UseApplePartNumbers() throws {
        let payload = "Content-Type: multipart/mixed; boundary=A\n\n--A\nContent-Type: multipart/related; boundary=B\n\n--B\n" + part().replacingOccurrences(of: "\r\n", with: "\n") + "\n--B--\n--A\nContent-Type: message/rfc822\n\nSubject: nested\nContent-Type: multipart/mixed; boundary=C\n\n--C\n" + part().replacingOccurrences(of: "\r\n", with: "\n") + "\n--C--\n--A--\n"
        let source = try fixture(Data(payload.utf8), attachments: ["1.1/blob.bin": Data([1, 2, 3]), "2.1/blob.bin": Data([4, 5, 6])])
        defer { cleanup(source) }
        let output = String(decoding: try convertEMLXToEML(at: source), as: UTF8.self)
        #expect(output.contains("AQID"))
        #expect(output.contains("BAUG"))
        #expect(!output.lowercased().contains("x-apple-content-length"))
    }

    @Test func foldedCaseInsensitiveHeadersAndDecodedFilename() throws {
        let payload = "cOnTeNt-TyPe: multipart/related;\r\n boundary=\"x;escaped\"\r\n\r\n--x;escaped\r\ncOnTeNt-TyPe: image/png\r\nContent-ID: <inline>\r\nContent-Disposition: inline;\r\n filename*=utf-8''caf%C3%A9.png\r\nx-APPLE-content-LENGTH:\r\n 3\r\n\r\n\r\n--x;escaped--\r\n"
        let source = try fixture(Data(payload.utf8), attachments: ["1/café.png": Data([1, 2, 3]), "1/other.png": Data([8, 8, 8])])
        defer { cleanup(source) }
        let output = String(decoding: try convertEMLXToEML(at: source), as: UTF8.self)
        #expect(output.contains("Content-ID: <inline>\r\n"))
        #expect(output.contains("Content-Transfer-Encoding: base64\r\n"))
        #expect(output.contains("AQID"))
    }

    @Test(arguments: ["filename*0*=utf-8''caf%C3; filename*1*=%A9.bin", "filename=\"=?UTF-8?B?Y2Fmw6kuYmlu?=\""])
    func decodesContinuedAndEncodedWordNames(parameter: String) throws {
        let payload = "Content-Type: application/octet-stream\nContent-Disposition: attachment; \(parameter)\nContent-Transfer-Encoding: base64\nX-Apple-Content-Length: 4\n\n"
        let source = try fixture(Data(payload.utf8), attachments: ["1/café.bin": Data([1, 2, 3]), "1/other": Data([8])])
        defer { cleanup(source) }
        #expect(String(decoding: try convertEMLXToEML(at: source), as: UTF8.self).contains("AQID"))
    }

    @Test func fallsBackToSingleRealFileAndIgnoresFinderMetadata() throws {
        let source = try fixture(Data(part().utf8), attachments: ["1/localized name": Data([1, 2, 3]), "1/.DS_Store": Data([9])])
        defer { cleanup(source) }
        let output = try convertEMLXToEML(at: source)
        #expect(String(decoding: output, as: UTF8.self).contains("AQID"))
    }

    @Test func zeroByteAttachmentIsRealAndRequired() throws {
        let source = try fixture(Data(part(length: "0").utf8), attachments: ["1/blob.bin": Data()])
        defer { cleanup(source) }
        #expect(try convertEMLXToEML(at: source) == Data(part(length: "0").replacingOccurrences(of: "X-Apple-Content-Length: 0\r\n", with: "").utf8))
        try FileManager.default.removeItem(at: source.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Attachments/42/1/blob.bin"))
        expectFailure(source, "missing_attachment")
    }

    @Test func missingAttachmentFailsInsteadOfExportingEmptyBody() throws {
        let source = try fixture(Data(part().utf8))
        defer { cleanup(source) }
        expectFailure(source, "missing_attachment")
    }

    @Test func ambiguousFallbackFails() throws {
        let source = try fixture(Data(part().utf8), attachments: ["1/a": Data([1, 2, 3]), "1/b": Data([1, 2, 3])])
        defer { cleanup(source) }
        expectFailure(source, "ambiguous_attachment")
    }

    @Test func truncatedAttachmentFailsEncodedLengthValidation() throws {
        let source = try fixture(Data(part(length: "138").utf8), attachments: ["1/blob.bin": Data([1, 2, 3])])
        defer { cleanup(source) }
        expectFailure(source, "attachment_size_mismatch")
    }

    @Test(arguments: ["-1", "oops", "4x"])
    func invalidDetachedLengthFails(length: String) throws {
        let source = try fixture(Data(part(length: length).utf8), attachments: ["1/blob.bin": Data([1, 2, 3])])
        defer { cleanup(source) }
        expectFailure(source, "malformed_attachment")
    }

    @Test func base64WrappingMatchesEncodedLengthAndDecodesExactly() throws {
        let bytes = Data((0..<100).map(UInt8.init))
        // 136 base64 characters plus one CRLF = 138 encoded bytes.
        let source = try fixture(Data(part(length: "138").utf8), attachments: ["1/blob.bin": bytes])
        defer { cleanup(source) }
        let output = try convertEMLXToEML(at: source)
        let text = String(decoding: output, as: UTF8.self)
        let body = try #require(text.components(separatedBy: "\r\n\r\n").last)
        #expect(body.components(separatedBy: "\r\n").map(\.count) == [76, 60])
        #expect(Data(base64Encoded: body, options: .ignoreUnknownCharacters) == bytes)
    }

    @Test func reconstructsQuotedPrintableAndSevenBitParts() throws {
        for (encoding, raw, length) in [("quoted-printable", Data([0xC3, 0xA9]), "6"), ("7bit", Data("hello".utf8), "5")] {
            let source = try fixture(Data(part(length: length, encoding: encoding).utf8), attachments: ["1/blob.bin": raw])
            defer { cleanup(source) }
            let output = String(decoding: try convertEMLXToEML(at: source), as: UTF8.self)
            #expect(output.contains(raw.base64EncodedString()))
            #expect(output.contains("Content-Transfer-Encoding: base64"))
        }
    }

    @Test func malformedMultipartCannotHideDetachedAttachment() throws {
        let payload = "Content-Type: multipart/mixed; boundary=missing\n\n--different\n" + part()
        let source = try fixture(Data(payload.utf8), attachments: ["1/blob.bin": Data([1, 2, 3])])
        defer { cleanup(source) }
        expectFailure(source, "malformed_mime")
    }
    @Test func zeroLengthPayloadCannotBeACompleteMessage() throws {
        let source = try fixture(Data(), prefix: "0\n")
        defer { cleanup(source) }
        expectFailure(source, "malformed_emlx")
    }

    @Test func recognizesAppleQuotedPrintableWordWrapping() throws {
        // 5,000 literal bytes; trailing space costs two extra bytes; 71 soft breaks cost 142.
        let raw = Data(String(repeating: "word ", count: 1000).utf8)
        let source = try fixture(Data(part(length: "5144", encoding: "quoted-printable").utf8), attachments: ["1/blob.bin": raw])
        defer { cleanup(source) }
        #expect(String(decoding: try convertEMLXToEML(at: source), as: UTF8.self).contains("Content-Transfer-Encoding: base64"))
    }

    @Test(arguments: ["base64", "quoted-printable"])
    func encodedRFC822AttachmentUsesItsChildNumber(encoding: String) throws {
        let nested = Data(part().replacingOccurrences(of: "\r\n", with: "\n").utf8)
        let encodedBody = encoding == "base64" ? nested.base64EncodedString() : String(decoding: nested, as: UTF8.self).replacingOccurrences(of: "=", with: "=3D").replacingOccurrences(of: "\n", with: "=0A")
        let payload = "Content-Type: multipart/mixed; boundary=A\r\n\r\n--A\r\nContent-Type: text/plain\r\n\r\nfirst\r\n--A\r\nContent-Type: message/rfc822\r\nContent-Transfer-Encoding: \(encoding)\r\n\r\n" + encodedBody + "\r\n--A--\r\n"
        let source = try fixture(Data(payload.utf8), attachments: ["2.1/blob.bin": Data([1, 2, 3])])
        defer { cleanup(source) }
        let output = String(decoding: try convertEMLXToEML(at: source), as: UTF8.self)
        let encoded = try #require(output.components(separatedBy: "Content-Transfer-Encoding: base64\r\n\r\n").last?.components(separatedBy: "\r\n--A--").first)
        let decoded = try #require(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
        #expect(String(decoding: decoded, as: UTF8.self).contains("AQID"))
        #expect(!String(decoding: decoded, as: UTF8.self).contains("X-Apple-Content-Length"))
        #expect(!decoded.contains(13))
    }

    @Test func repairsOnlyVerifiedAppleFinalBoundaryHyphenQuirk() throws {
        let payload = Data(("Content-Type: multipart/mixed; boundary=end\n\n--end\n" + part().replacingOccurrences(of: "\r\n", with: "\n") + "\n--end-").utf8)
        let source = try fixture(payload, attachments: ["1/blob.bin": Data([1, 2, 3])])
        defer { cleanup(source) }
        // The known Apple quirk puts the plist immediately after the single hyphen.
        try (Data("\(payload.count)\n".utf8) + payload + Data("<?xml version=\"1.0\"?><plist><dict/></plist>".utf8)).write(to: source)
        let output = String(decoding: try convertEMLXToEML(at: source), as: UTF8.self)
        #expect(output.hasSuffix("--end--"))
        #expect(output.contains("AQID"))
        // A merely malformed delimiter without that framing evidence is still an error.
        try (Data("\(payload.count)\n".utf8) + payload + Data("\n<?xml version=\"1.0\"?><plist><dict/></plist>".utf8)).write(to: source)
        expectFailure(source, "malformed_mime")
    }

    @Test func whitespaceIndentedBoundaryIsNotADelimiter() throws {
        let payload = "Content-Type: multipart/mixed; boundary=x\n\n --x\n" + part().replacingOccurrences(of: "\r\n", with: "\n") + "\n --x--\n"
        let source = try fixture(Data(payload.utf8), attachments: ["1/blob.bin": Data([1, 2, 3])])
        defer { cleanup(source) }
        expectFailure(source, "malformed_mime")
    }

    @Test(arguments: ["", "   ", ";", "; name=blob.bin"])
    func emptyMediaTypeIsTypedFailure(contentType: String) throws {
        let payload = "Content-Type: \(contentType)\r\nContent-Transfer-Encoding: base64\r\nX-Apple-Content-Length: 4\r\n\r\n"
        let source = try fixture(Data(payload.utf8), attachments: ["1/blob.bin": Data([1, 2, 3])])
        defer { cleanup(source) }
        expectFailure(source, "malformed_mime")
    }

    @Test(arguments: ["7bit", "base64"])
    func digestDefaultsChildrenToRFC822(encoding: String) throws {
        let nested = part().replacingOccurrences(of: "\r\n", with: "\n")
        let wrapped = encoding == "base64" ? Data(nested.utf8).base64EncodedString() : nested
        let payload = "Content-Type: multipart/digest; boundary=digest\n\n--digest\nContent-Transfer-Encoding: \(encoding)\n\n" + wrapped + "\n--digest--\n"
        let source = try fixture(Data(payload.utf8), attachments: ["1.1/blob.bin": Data([1, 2, 3])])
        defer { cleanup(source) }
        let output = String(decoding: try convertEMLXToEML(at: source), as: UTF8.self)
        let nestedOutput: String
        if encoding == "base64" {
            let encoded = try #require(output.components(separatedBy: "Content-Transfer-Encoding: base64\n\n").last?.components(separatedBy: "\n--digest--").first)
            nestedOutput = String(decoding: try #require(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)), as: UTF8.self)
        } else { nestedOutput = output }
        #expect(nestedOutput.contains("AQID"))
        #expect(!nestedOutput.contains("X-Apple-Content-Length"))
    }

    @Test(arguments: [(1500, "2066"), (100, "144")])
    func acceptsConformingBase64LineWrapping(example: (Int, String)) throws {
        // 1,500 raw bytes -> 2,000 chars, 60-column lines and 33 CRLFs -> 2,066.
        // 100 raw bytes -> 136 chars, irregular lines of 10/20/30/40/36 -> 144.
        let raw = Data((0..<example.0).map { UInt8($0 % 256) })
        let source = try fixture(Data(part(length: example.1).utf8), attachments: ["1/blob.bin": raw])
        defer { cleanup(source) }
        let output = String(decoding: try convertEMLXToEML(at: source), as: UTF8.self)
        let body = try #require(output.components(separatedBy: "\r\n\r\n").last)
        #expect(Data(base64Encoded: body, options: .ignoreUnknownCharacters) == raw)
    }

    @Test func finderMetadataPrefixIsALegitimateAttachmentName() throws {
        let source = try fixture(Data(part().utf8), attachments: ["1/.DS_Store-notes.txt": Data([1, 2, 3]), "1/.DS_Store": Data([9])])
        defer { cleanup(source) }
        #expect(String(decoding: try convertEMLXToEML(at: source), as: UTF8.self).contains("AQID"))
    }

    @Test func unknownQuotedPrintableLengthIsUnverifiedRatherThanCorrupt() throws {
        let source = try fixture(Data(part(length: "99", encoding: "quoted-printable").utf8), attachments: ["1/blob.bin": Data([0xC3, 0xA9])])
        defer { cleanup(source) }
        expectFailure(source, "unverified_attachment_size")
    }

    @Test func vanishedAttachmentMetadataHasTypedFailure() throws {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        do {
            _ = try regularAttachmentFiles([missing])
            Issue.record("Expected unreadable attachment metadata failure")
        } catch let error as EMLConversionError {
            #expect(error.reasonCode == "unreadable_attachment")
        } catch {
            Issue.record("Metadata failure escaped conversion error type: \(error)")
        }
    }

}
