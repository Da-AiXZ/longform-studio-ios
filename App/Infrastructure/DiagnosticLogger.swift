import Foundation

struct DiagnosticEntry: Codable, Identifiable, Sendable {
    var id = UUID()
    var timestamp = Date()
    var category: String
    var message: String
}

actor DiagnosticLogger {
    static let shared = DiagnosticLogger()
    private var entries: [DiagnosticEntry]
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        let manager = FileManager.default
        let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? manager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let resolvedURL = fileURL ?? base.appendingPathComponent("LongformStudio/Diagnostics/events.json")
        self.fileURL = resolvedURL
        if let data = try? Data(contentsOf: resolvedURL),
           let decoded = try? JSONDecoder.iso8601.decode([DiagnosticEntry].self, from: data) {
            entries = Array(decoded.suffix(500))
        } else {
            entries = []
        }
    }

    func log(category: String, message: String, secrets: [String] = []) {
        var redacted = message
        for secret in secrets where !secret.isEmpty {
            redacted = redacted.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
        redacted = Self.redactAuthorization(redacted)
        redacted = Self.removeLikelyManuscriptText(redacted)
        entries.append(DiagnosticEntry(category: String(category.prefix(80)), message: String(redacted.prefix(2_000))))
        if entries.count > 500 { entries.removeFirst(entries.count - 500) }
        persist()
    }

    func exportData() throws -> Data { try JSONEncoder.prettyISO8601.encode(entries) }
    func allEntries() -> [DiagnosticEntry] { entries }

    static func redactAuthorization(_ input: String) -> String {
        let patterns = [
            "(?i)(Authorization\\s*[:=]\\s*)([^\\s,}]+(?:\\s+[^\\s,}]+)?)",
            "(?i)(api[-_ ]?key\\s*[:=]\\s*)([^\\s,}]+)",
            "(?i)(\\b(?:sk|key)[-_])[A-Za-z0-9_-]{12,}"
        ]
        return patterns.reduce(input) { current, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return current }
            let range = NSRange(current.startIndex..<current.endIndex, in: current)
            return regex.stringByReplacingMatches(in: current, range: range, withTemplate: "$1[REDACTED]")
        }
    }

    private static func removeLikelyManuscriptText(_ input: String) -> String {
        let chineseCount = input.unicodeScalars.filter { (0x3400...0x9FFF).contains($0.value) }.count
        guard input.count > 600 || chineseCount > 60 else { return input }
        return "[LONG_TEXT_REDACTED]"
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder.prettyISO8601.encode(entries).write(to: fileURL, options: [.atomic])
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: fileURL.path)
        } catch {
            // Diagnostics must never interrupt writing or saving.
        }
    }
}

private extension JSONEncoder {
    static var prettyISO8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
