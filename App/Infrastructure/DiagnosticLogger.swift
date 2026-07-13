import Foundation

struct DiagnosticEntry: Codable, Identifiable, Sendable {
    var id = UUID()
    var timestamp = Date()
    var category: String
    var message: String
}

actor DiagnosticLogger {
    static let shared = DiagnosticLogger()
    private var entries: [DiagnosticEntry] = []

    func log(category: String, message: String, secrets: [String] = []) {
        var redacted = message
        for secret in secrets where !secret.isEmpty {
            redacted = redacted.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
        redacted = Self.redactAuthorization(redacted)
        entries.append(DiagnosticEntry(category: category, message: String(redacted.prefix(4_000))))
        if entries.count > 500 { entries.removeFirst(entries.count - 500) }
    }

    func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(entries)
    }

    func allEntries() -> [DiagnosticEntry] { entries }

    static func redactAuthorization(_ input: String) -> String {
        let patterns = [
            "(?i)(Authorization\\s*[:=]\\s*)([^\\s,}]+(?:\\s+[^\\s,}]+)?)",
            "(?i)(api[-_ ]?key\\s*[:=]\\s*)([^\\s,}]+)"
        ]
        return patterns.reduce(input) { current, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return current }
            let range = NSRange(current.startIndex..<current.endIndex, in: current)
            return regex.stringByReplacingMatches(in: current, range: range, withTemplate: "$1[REDACTED]")
        }
    }
}
