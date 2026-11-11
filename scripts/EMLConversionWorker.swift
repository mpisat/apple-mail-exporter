import Darwin
import Foundation

private struct ConversionJob: Decodable {
    let source: String
    let output: String
}

private struct ConversionReply: Encodable {
    let status: String
    let reason: String?
    let detail: String?
}

@main struct EMLConversionWorker {
    static func main() throws {
        _ = umask(0o077)
        guard CommandLine.arguments.count == 3,
              let maximum = Int(CommandLine.arguments[2]), maximum >= 0 else { exit(2) }
        let requestedRoot = CommandLine.arguments[1]
        let root = URL(fileURLWithPath: requestedRoot).standardizedFileURL.resolvingSymlinksInPath()
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let fm = FileManager.default
        var directories: Set<String> = [root.path]
        for _ in 0..<maximum {
            guard let line = readLine() else { break }
            let reply: ConversionReply
            do {
                let job = try decoder.decode(ConversionJob.self, from: Data(line.utf8))
                let source = URL(fileURLWithPath: job.source)
                guard let matchingRoot = [requestedRoot, root.path].first(where: { job.output.hasPrefix($0 + "/") }) else {
                    throw EMLConversionError(reasonCode: "unsafe_output", detail: "Output is outside the requested export root")
                }
                let relative = String(job.output.dropFirst(matchingRoot.count + 1))
                guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else {
                    throw EMLConversionError(reasonCode: "unsafe_output", detail: "Invalid relative output path")
                }
                // Anchor the relative path to the same canonical URL: macOS resolves
                // existing /private/var roots to /var but leaves new absolute descendants alone.
                let output = root.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
                guard output.path.hasPrefix(root.path + "/"),
                      output.pathExtension == "eml" else {
                    throw EMLConversionError(reasonCode: "unsafe_output", detail: "Output \(output.path) is outside root \(root.path); extension \(output.pathExtension)")
                }
                guard !fm.fileExists(atPath: output.path) else {
                    throw EMLConversionError(reasonCode: "output_exists", detail: "Refusing to overwrite an existing EML")
                }
                let content = try convertEMLXToEML(at: source)
                let parent = output.deletingLastPathComponent()
                if !directories.contains(parent.path) {
                    try fm.createDirectory(at: parent, withIntermediateDirectories: true,
                                           attributes: [.posixPermissions: 0o700])
                    directories.insert(parent.path)
                }
                try content.write(to: output, options: .atomic)
                reply = ConversionReply(status: "exported", reason: nil, detail: nil)
            } catch let error as EMLConversionError {
                reply = ConversionReply(status: "failed", reason: error.reasonCode, detail: error.detail)
            } catch {
                reply = ConversionReply(status: "failed", reason: "io_error", detail: error.localizedDescription)
            }
            var response = try encoder.encode(reply)
            response.append(10)
            try FileHandle.standardOutput.write(contentsOf: response)
        }
    }
}
