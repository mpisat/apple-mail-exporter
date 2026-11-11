import Foundation

/// A message that cannot be exported completely is reported instead of silently losing data.
public struct EMLConversionError: Error, LocalizedError, Sendable {
    public let reasonCode: String
    public let detail: String

    public init(reasonCode: String, detail: String) {
        self.reasonCode = reasonCode
        self.detail = detail
    }

    public var errorDescription: String? { detail }
}

/// Removes EMLX framing and restores locally detached MIME bodies.
/// Embedded message bytes are preserved; only detached MIME headers and bodies are rewritten.
public func convertEMLXToEML(at source: URL) throws -> Data {
    let raw: Data
    do {
        raw = try Data(contentsOf: source)
    } catch {
        throw EMLConversionError(reasonCode: "unreadable_message", detail: "Cannot read message: \(error.localizedDescription)")
    }
    guard let newline = raw.firstIndex(of: 10),
          let prefix = String(data: raw[..<newline], encoding: .ascii) else {
        throw EMLConversionError(reasonCode: "malformed_emlx", detail: "EMLX has no decimal byte-count line")
    }
    let digits = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }), let count = Int(digits), count > 0 else {
        throw EMLConversionError(reasonCode: "malformed_emlx", detail: "Invalid EMLX byte count")
    }
    let start = raw.index(after: newline)
    guard count <= raw.count - start else {
        throw EMLConversionError(reasonCode: "truncated_emlx", detail: "EMLX payload is shorter than its declared byte count")
    }
    let payload = Data(raw[start..<(start + count)])
    // Most messages need framing removal only. Inspect bytes without decoding or copying
    // the whole body into strings; encoded attached messages still need MIME traversal.
    if !containsASCII(payload, "x-apple-content-length:") &&
        !containsASCII(payload, "message/rfc822") && !containsASCII(payload, "message/global") &&
        !containsASCII(payload, "multipart/digest") {
        return payload
    }
    let messageID = source.lastPathComponent.components(separatedBy: ".")[0]
    let attachmentRoot = source.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Attachments").appendingPathComponent(messageID)
    let shortFinalBoundary = source.lastPathComponent.hasSuffix(".partial.emlx") &&
        raw[(start + count)...].starts(with: Data("<?xml".utf8))
    return try MIMERebuilder(data: payload, attachmentRoot: attachmentRoot, allowShortFinalBoundary: shortFinalBoundary).rebuild()
}

private func containsASCII(_ data: Data, _ pattern: String) -> Bool {
    let needle = Array(pattern.utf8)
    return data.withUnsafeBytes { buffer in
        let bytes = buffer.bindMemory(to: UInt8.self)
        guard bytes.count >= needle.count else { return false }
        for offset in 0...(bytes.count - needle.count) {
            let first = bytes[offset]
            guard first == needle[0] || ((65...90).contains(first) && first + 32 == needle[0]) else { continue }
            var matches = true
            for index in 1..<needle.count {
                let byte = bytes[offset + index]
                if byte != needle[index] && !((65...90).contains(byte) && byte + 32 == needle[index]) {
                    matches = false
                    break
                }
            }
            if matches { return true }
        }
        return false
    }
}

private struct MIMEHeader {
    let name: String
    var value: String
    var range: Range<Int>
}

private struct MIMEEdit {
    let range: Range<Int>
    let replacement: Data
}

private struct MIMERebuilder {
    let bytes: [UInt8]
    let attachmentRoot: URL
    let allowShortFinalBoundary: Bool
    var edits: [MIMEEdit] = []

    init(data: Data, attachmentRoot: URL, allowShortFinalBoundary: Bool = false) {
        self.allowShortFinalBoundary = allowShortFinalBoundary
        self.bytes = Array(data)
        self.attachmentRoot = attachmentRoot
    }

    func rebuild(partPath: [Int] = []) throws -> Data {
        var parser = self
        try parser.visit(0..<bytes.count, path: partPath)
        guard !parser.edits.isEmpty else { return Data(bytes) }
        var output = Data()
        var position = 0
        for edit in parser.edits.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            output.append(contentsOf: bytes[position..<edit.range.lowerBound])
            output.append(edit.replacement)
            position = edit.range.upperBound
        }
        output.append(contentsOf: bytes[position...])
        return output
    }

    private func fail(_ reason: String, _ detail: String) -> EMLConversionError {
        EMLConversionError(reasonCode: reason, detail: detail)
    }

    private func line(at start: Int, limit: Int) -> (content: Range<Int>, end: Int) {
        var end = start
        while end < limit && bytes[end] != 10 { end += 1 }
        let next = end < limit ? end + 1 : end
        if end > start && bytes[end - 1] == 13 { end -= 1 }
        return (start..<end, next)
    }

    private func text(_ range: Range<Int>) -> String {
        String(decoding: bytes[range], as: UTF8.self)
    }

    private func hasDetachedMarker(_ range: Range<Int>) -> Bool {
        var position = range.lowerBound
        while position < range.upperBound {
            let current = line(at: position, limit: range.upperBound)
            if text(current.content).lowercased().hasPrefix("x-apple-content-length:") { return true }
            position = current.end
        }
        return false
    }

    private func headers(in range: Range<Int>) throws -> (fields: [MIMEHeader], body: Int, newline: String)? {
        var fields: [MIMEHeader] = []
        var position = range.lowerBound
        var newline = "\r\n"
        while position < range.upperBound {
            let current = line(at: position, limit: range.upperBound)
            if current.end > current.content.upperBound {
                newline = current.end - current.content.upperBound == 2 ? "\r\n" : "\n"
            }
            if current.content.isEmpty { return (fields, current.end, newline) }
            let value = text(current.content)
            if bytes[position] == 32 || bytes[position] == 9 {
                guard !fields.isEmpty else {
                    if hasDetachedMarker(range) { throw fail("malformed_mime", "MIME header continuation has no field") }
                    return nil
                }
                fields[fields.count - 1].value = (fields[fields.count - 1].value + " " + value).trimmingCharacters(in: .whitespaces)
                fields[fields.count - 1].range = fields[fields.count - 1].range.lowerBound..<current.end
            } else if let colon = value.firstIndex(of: ":") {
                let name = value[..<colon].lowercased()
                fields.append(MIMEHeader(name: name, value: String(value[value.index(after: colon)...]).trimmingCharacters(in: .whitespaces), range: position..<current.end))
            } else {
                if hasDetachedMarker(range) { throw fail("malformed_mime", "Malformed header in a detached MIME message") }
                return nil
            }
            position = current.end
        }
        if hasDetachedMarker(range) { throw fail("malformed_mime", "Detached MIME part has no header/body separator") }
        return nil
    }

    private mutating func visit(_ range: Range<Int>, path: [Int], defaultContentType: String = "text/plain") throws {
        guard let block = try headers(in: range) else { return }
        let fields = block.fields
        func value(_ name: String) -> String? { fields.first(where: { $0.name == name })?.value }
        let contentType = value("content-type") ?? defaultContentType
        let mediaType = contentType.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        guard !mediaType.isEmpty else { throw fail("malformed_mime", "MIME Content-Type has no media type") }
        let detached = fields.filter { $0.name == "x-apple-content-length" }
        if !detached.isEmpty {
            guard detached.count == 1, !mediaType.hasPrefix("multipart/") else {
                throw fail("malformed_attachment", "Invalid or duplicate detached-content header")
            }
            let declared = detached[0].value
            guard !declared.isEmpty, declared.utf8.allSatisfy({ (48...57).contains($0) }), let count = Int(declared) else {
                throw fail("malformed_attachment", "Invalid detached-content byte count")
            }
            let slot = path.isEmpty ? [1] : path
            let raw = try attachment(fields: fields, slot: slot)
            let encodings = fields.filter { $0.name == "content-transfer-encoding" }
            guard encodings.count <= 1 else { throw fail("malformed_attachment", "Duplicate transfer-encoding header") }
            let encoding = value("content-transfer-encoding")?.lowercased() ?? "7bit"
            try validateLength(raw, declared: count, encoding: encoding, mediaType: mediaType)
            let preserveAttachedMessage = mediaType == "message/rfc822" && ["7bit", "8bit", "binary"].contains(encoding)
            let replacementEncoding = preserveAttachedMessage ? encoding : "base64"
            for field in detached { edits.append(MIMEEdit(range: field.range, replacement: Data())) }
            if let field = encodings.first {
                if encoding != replacementEncoding {
                    edits.append(MIMEEdit(range: field.range, replacement: Data("Content-Transfer-Encoding: \(replacementEncoding)\(block.newline)".utf8)))
                }
            } else if !preserveAttachedMessage {
                // Insert before the blank separator, after the final header line.
                let insertion = fields.last?.range.upperBound ?? range.lowerBound
                edits.append(MIMEEdit(range: insertion..<insertion, replacement: Data("Content-Transfer-Encoding: base64\(block.newline)".utf8)))
            }
            // RFC 2046 permits raw 7bit/8bit/binary attached messages; retain their bytes and encoding.
            let restoredBody = preserveAttachedMessage ? raw : base64(raw, newline: block.newline)
            edits.append(MIMEEdit(range: block.body..<range.upperBound, replacement: restoredBody))
            return
        }

        if mediaType.hasPrefix("multipart/") {
            guard let boundary = parameters(contentType)["boundary"], !boundary.isEmpty,
                  !boundary.contains("\r"), !boundary.contains("\n") else {
                if hasDetachedMarker(range) { throw fail("malformed_mime", "Detached message has no valid multipart boundary") }
                return
            }
            let delimiter = "--" + boundary
            var position = block.body
            var childStart: Int?
            var childNumber = 0
            var closed = false
            while position < range.upperBound {
                let current = line(at: position, limit: range.upperBound)
                let candidate = String(text(current.content).reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed())
                // A verified Mail.app quirk omits only the final hyphen immediately before
                // the plist. Require both EMLX framing evidence and the exact outer boundary.
                let shortClose = allowShortFinalBoundary && path.isEmpty && range.upperBound == bytes.count &&
                    current.end == bytes.count && candidate == delimiter + "-"
                if candidate == delimiter || candidate == delimiter + "--" || shortClose {
                    if let start = childStart {
                        var end = position
                        // A boundary's preceding newline belongs to the delimiter, not the MIME body.
                        if end > start && bytes[end - 1] == 10 {
                            end -= 1
                            if end > start && bytes[end - 1] == 13 { end -= 1 }
                        }
                        childNumber += 1
                        // RFC 2046 section 5.1.5 gives digest children a message/rfc822 default.
                        try visit(start..<end, path: path + [childNumber], defaultContentType: mediaType == "multipart/digest" ? "message/rfc822" : "text/plain")
                    }
                    if candidate == delimiter + "--" || shortClose {
                        if shortClose { edits.append(MIMEEdit(range: bytes.count..<bytes.count, replacement: Data("-".utf8))) }
                        closed = true
                        break
                    }
                    childStart = current.end
                }
                position = current.end
            }
            if !closed && hasDetachedMarker(range) {
                throw fail("malformed_mime", "Detached message has an incomplete multipart boundary structure")
            }
        } else if mediaType == "message/rfc822" || mediaType == "message/global" {
            let encoding = value("content-transfer-encoding")?.lowercased() ?? "7bit"
            if encoding == "base64" || encoding == "quoted-printable" {
                let encoded = Data(bytes[block.body..<range.upperBound])
                let decoded: Data?
                if encoding == "base64" {
                    decoded = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)
                } else {
                    decoded = decodeQuotedPrintable(encoded)
                }
                guard let decoded else { return }
                let nested = MIMERebuilder(data: decoded, attachmentRoot: attachmentRoot)
                let nestedType = try nested.headers(in: 0..<nested.bytes.count)?.fields.first(where: { $0.name == "content-type" })?.value.lowercased() ?? "text/plain"
                let output = try nested.rebuild(partPath: nestedType.hasPrefix("multipart/") ? path : path + [1])
                if output != decoded {
                    // Re-encoding as base64 preserves every decoded byte, including mixed
                    // line endings and binary regions inside the encapsulated message.
                    if encoding != "base64", let field = fields.first(where: { $0.name == "content-transfer-encoding" }) {
                        edits.append(MIMEEdit(range: field.range, replacement: Data("Content-Transfer-Encoding: base64\(block.newline)".utf8)))
                    }
                    edits.append(MIMEEdit(range: block.body..<range.upperBound, replacement: base64(output, newline: block.newline)))
                }
            } else {
                // Encapsulated multipart children are numbered directly under the message part.
                let nestedRange = block.body..<range.upperBound
                let nestedType = try headers(in: nestedRange)?.fields.first(where: { $0.name == "content-type" })?.value.lowercased() ?? "text/plain"
                try visit(nestedRange, path: nestedType.hasPrefix("multipart/") ? path : path + [1])
            }
        }
    }

    private func attachment(fields: [MIMEHeader], slot: [Int]) throws -> Data {
        let directory = attachmentRoot.appendingPathComponent(slot.map(String.init).joined(separator: "."))
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                .filter { $0.lastPathComponent != ".DS_Store" }
        } catch {
            throw fail("missing_attachment", "Missing attachment slot \(slot.map(String.init).joined(separator: "."))")
        }
        let files = try regularAttachmentFiles(entries)
        let disposition = fields.first(where: { $0.name == "content-disposition" })?.value ?? ""
        let contentType = fields.first(where: { $0.name == "content-type" })?.value ?? ""
        let dispositionParameters = parameters(disposition)
        let typeParameters = parameters(contentType)
        let names = [decodedParameter("filename", in: dispositionParameters), decodedParameter("name", in: typeParameters), decodedParameter("filename", in: typeParameters)].compactMap { $0 }
        var chosen: URL?
        for name in names where !name.contains("/") && !name.contains("\\") && name != "." && name != ".." {
            if let file = files.first(where: { $0.lastPathComponent.precomposedStringWithCanonicalMapping == name.precomposedStringWithCanonicalMapping }) {
                chosen = file
                break
            }
        }
        if chosen == nil {
            guard files.count == 1 else {
                throw fail(files.isEmpty ? "missing_attachment" : "ambiguous_attachment", "Cannot select a unique attachment file in slot \(slot.map(String.init).joined(separator: "."))")
            }
            chosen = files[0]
        }
        guard let chosen else { throw fail("missing_attachment", "Missing attachment") }
        do { return try Data(contentsOf: chosen) } catch {
            throw fail("unreadable_attachment", "Cannot read attachment: \(error.localizedDescription)")
        }
    }

    private func validateLength(_ raw: Data, declared: Int, encoding: String, mediaType: String) throws {
        var lengths: Set<Int> = []
        switch encoding {
        case "base64":
            let characters = raw.count / 3 * 4 + (raw.count % 3 == 0 ? 0 : 4)
            // RFC 2045 permits arbitrary line lengths up to 76 characters. Each
            // intervening line break contributes one or two bytes; a final break is optional.
            // Irregular wrapping is valid, so matching a shortlist of fixed widths loses mail.
            let minimumBreaks = characters == 0 ? 0 : (characters - 1) / 76
            if declared >= characters {
                let lineBreakBytes = declared - characters
                if lineBreakBytes >= minimumBreaks && lineBreakBytes <= characters * 2 {
                    lengths.insert(declared)
                }
            }
        case "7bit", "8bit", "binary", "":
            if encoding == "7bit" && raw.contains(where: { $0 > 127 }) {
                throw fail("malformed_attachment", "A 7bit attachment contains non-ASCII bytes")
            }
            // Some Mail caches retain a short earlier length for a larger, full
            // attached email. Require complete header framing before allowing that case.
            if mediaType == "message/rfc822", raw.count > declared {
                let nested = MIMERebuilder(data: raw, attachmentRoot: attachmentRoot)
                guard let header = try nested.headers(in: 0..<nested.bytes.count), !header.fields.isEmpty else {
                    throw fail("malformed_attachment", "Attached message has no complete header framing")
                }
                return
            }
            lengths.insert(raw.count)
            if (encoding == "7bit" || encoding == "8bit"), mediaType.hasPrefix("text/") {
                // Mail can cache text/calendar with LF while retaining the CRLF wire size.
                // Accept that exact canonical-size difference without changing cached bytes.
                var canonicalLength = raw.count
                var previous: UInt8?
                for byte in raw {
                    if byte == 10 && previous != 13 { canonicalLength += 1 }
                    previous = byte
                }
                lengths.insert(canonicalLength)
            }
        case "quoted-printable":
            for lineEnding in ["\n", "\r\n"] {
                for wordWrap in [false, true] {
                    for width in [72, 75, 76] {
                        let encoded = quotedPrintable(raw, newline: lineEnding, wordWrap: wordWrap, width: width)
                        lengths.insert(encoded.count)
                        lengths.insert(encoded.count + lineEnding.utf8.count)
                        if encoded.suffix(lineEnding.utf8.count) == Data(lineEnding.utf8) { lengths.insert(encoded.count - lineEnding.utf8.count) }
                    }
                }
            }
        default:
            throw fail("unsupported_transfer_encoding", "Unsupported detached transfer encoding: \(encoding)")
        }
        guard lengths.contains(declared) else {
            if encoding == "quoted-printable" {
                throw fail("unverified_attachment_size", "Cannot verify detached quoted-printable size against known encoders (declared \(declared)); the source may use different wrapping")
            }
            throw fail("attachment_size_mismatch", "Attachment does not match the declared transfer-encoded byte count (\(declared))")
        }
    }
}

private func base64(_ data: Data, newline: String) -> Data {
    let encoded = Array(data.base64EncodedData())
    var output = Data()
    var position = 0
    while position < encoded.count {
        if position > 0 { output.append(contentsOf: newline.utf8) }
        let end = min(position + 76, encoded.count)
        output.append(contentsOf: encoded[position..<end])
        position = end
    }
    return output
}

/// Splits MIME parameters without mistaking semicolons inside quoted strings for separators.
private func parameters(_ header: String) -> [String: String] {
    var components: [String] = []
    var current = ""
    var quoted = false
    var escaped = false
    for character in header {
        if escaped { current.append(character); escaped = false }
        else if character == "\\" && quoted { escaped = true }
        else if character == "\"" { quoted.toggle() }
        else if character == ";" && !quoted { components.append(current); current = "" }
        else { current.append(character) }
    }
    components.append(current)
    var result: [String: String] = [:]
    for component in components.dropFirst() {
        guard let equals = component.firstIndex(of: "=") else { continue }
        let key = component[..<equals].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        result[key] = component[component.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return result
}

private func decodedParameter(_ key: String, in values: [String: String]) -> String? {
    if let value = values[key + "*"] { return decodeExtendedParameter(value) }
    var chunks: [String] = []
    var extended = false
    var index = 0
    while let value = values[key + "*\(index)*"] ?? values[key + "*\(index)"] {
        if values[key + "*\(index)*"] != nil { extended = true }
        chunks.append(value)
        index += 1
    }
    if !chunks.isEmpty { return extended ? decodeExtendedParameter(chunks.joined()) : decodeEncodedWord(chunks.joined()) }
    return values[key].map(decodeEncodedWord)
}

private func decodeExtendedParameter(_ value: String) -> String? {
    let segments = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
    let charset = segments.count == 3 ? String(segments[0]).lowercased() : "utf-8"
    let encoded = segments.count == 3 ? String(segments[2]) : value
    let bytes = Array(encoded.utf8)
    var decoded = Data()
    var index = 0
    while index < bytes.count {
        if bytes[index] == 37 {
            guard index + 2 < bytes.count, let number = UInt8(String(decoding: bytes[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) else { return nil }
            decoded.append(number)
            index += 3
        } else { decoded.append(bytes[index]); index += 1 }
    }
    return decodeText(decoded, charset: charset)
}

private func decodeText(_ data: Data, charset: String) -> String? {
    switch charset.lowercased() {
    case "utf-8", "utf8", "us-ascii": return String(data: data, encoding: .utf8)
    case "iso-8859-1", "latin1", "latin-1": return String(data: data, encoding: .isoLatin1)
    case "windows-1252": return String(data: data, encoding: .windowsCP1252)
    default: return nil
    }
}

private func decodeEncodedWord(_ value: String) -> String {
    var remaining = value[...]
    var output = ""
    while let start = remaining.range(of: "=?"), let end = remaining[start.upperBound...].range(of: "?=") {
        output += remaining[..<start.lowerBound]
        let token = remaining[start.upperBound..<end.lowerBound].split(separator: "?", maxSplits: 2, omittingEmptySubsequences: false)
        guard token.count == 3 else { return value }
        let data: Data?
        if token[1].lowercased() == "b" { data = Data(base64Encoded: String(token[2])) }
        else if token[1].lowercased() == "q" { data = decodeQuotedPrintable(Data(token[2].replacingOccurrences(of: "_", with: " ").utf8)) }
        else { return value }
        guard let data, let decoded = decodeText(data, charset: String(token[0])) else { return value }
        output += decoded
        remaining = remaining[end.upperBound...]
        if remaining.trimmingCharacters(in: .whitespaces).hasPrefix("=?") { remaining = Substring(remaining.trimmingCharacters(in: .whitespaces)) }
    }
    return output + remaining
}

private func decodeQuotedPrintable(_ data: Data) -> Data? {
    let bytes = Array(data)
    var output = Data()
    var index = 0
    while index < bytes.count {
        if bytes[index] != 61 { output.append(bytes[index]); index += 1; continue }
        if index + 1 < bytes.count && bytes[index + 1] == 10 { index += 2; continue }
        if index + 2 < bytes.count && bytes[index + 1] == 13 && bytes[index + 2] == 10 { index += 3; continue }
        guard index + 2 < bytes.count, let byte = UInt8(String(decoding: bytes[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) else { return nil }
        output.append(byte)
        index += 3
    }
    return output
}

private func quotedPrintable(_ data: Data, newline: String, wordWrap: Bool, width: Int = 75) -> Data {
    let bytes = Array(data)
    var lines: [[String]] = [[]]
    var index = 0
    while index < bytes.count {
        let byte = bytes[index]
        if byte == 10 || (byte == 13 && index + 1 < bytes.count && bytes[index + 1] == 10) {
            lines.append([])
            index += byte == 13 ? 2 : 1
            continue
        }
        let trailingWhitespace = (byte == 32 || byte == 9) && (index + 1 == bytes.count || bytes[index + 1] == 10 || bytes[index + 1] == 13)
        if ((33...60).contains(byte) || (62...126).contains(byte) || byte == 32 || byte == 9) && !trailingWhitespace {
            lines[lines.count - 1].append(String(UnicodeScalar(byte)))
        } else { lines[lines.count - 1].append(String(format: "=%02X", byte)) }
        index += 1
    }
    var rendered: [String] = []
    for tokens in lines {
        var rest = tokens[...]
        var result = ""
        while !rest.isEmpty {
            var count = 0
            var end = rest.startIndex
            var space: Int?
            while end < rest.endIndex && count + rest[end].utf8.count <= width {
                count += rest[end].utf8.count
                if rest[end] == " " || rest[end] == "\t" { space = end + 1 }
                end += 1
            }
            if end == rest.endIndex { result += rest.joined(); break }
            if wordWrap, let space { end = space }
            result += rest[..<end].joined() + "=" + newline
            rest = rest[end...]
        }
        rendered.append(result)
    }
    return Data(rendered.joined(separator: newline).utf8)
}

// Kept as one filesystem boundary so a file disappearing after enumeration is reported consistently.
func regularAttachmentFiles(_ entries: [URL]) throws -> [URL] {
    do {
        return try entries.filter {
            let values = try $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return values.isRegularFile == true && values.isSymbolicLink != true
        }
    } catch {
        throw EMLConversionError(reasonCode: "unreadable_attachment", detail: "Cannot inspect attachment: \(error.localizedDescription)")
    }
}
