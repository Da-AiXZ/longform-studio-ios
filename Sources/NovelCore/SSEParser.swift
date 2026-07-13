import Foundation

public enum SSEEvent: Equatable, Sendable {
    case text(String)
    case finished(String?)
    case done
}

private struct StreamEnvelope: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
        }
        let delta: Delta
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }
    let choices: [Choice]
}

public struct SSEParser: Sendable {
    private var buffer = ""

    public init() {}

    public mutating func feed(_ chunk: String) throws -> [SSEEvent] {
        buffer += chunk.replacingOccurrences(of: "\r\n", with: "\n")
        var events: [SSEEvent] = []

        while let range = buffer.range(of: "\n\n") {
            let block = String(buffer[..<range.lowerBound])
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            events.append(contentsOf: try parse(block: block))
        }
        return events
    }

    public mutating func finish() throws -> [SSEEvent] {
        guard !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        defer { buffer = "" }
        return try parse(block: buffer)
    }

    private func parse(block: String) throws -> [SSEEvent] {
        let payloads = block.components(separatedBy: .newlines).compactMap { line -> String? in
            guard line.hasPrefix("data:") else { return nil }
            return String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }
        var events: [SSEEvent] = []
        let decoder = JSONDecoder()
        for payload in payloads where !payload.isEmpty {
            if payload == "[DONE]" {
                events.append(.done)
                continue
            }
            let envelope = try decoder.decode(StreamEnvelope.self, from: Data(payload.utf8))
            for choice in envelope.choices {
                if let content = choice.delta.content, !content.isEmpty { events.append(.text(content)) }
                if choice.finishReason != nil { events.append(.finished(choice.finishReason)) }
            }
        }
        return events
    }
}

public enum TextContinuationMerger {
    public static func merge(existing: String, continuation: String, maximumOverlap: Int = 400) -> String {
        guard !existing.isEmpty, !continuation.isEmpty else { return existing + continuation }
        let maxLength = min(maximumOverlap, existing.count, continuation.count)
        guard maxLength > 0 else { return existing + continuation }

        for length in stride(from: maxLength, through: 1, by: -1) {
            let existingStart = existing.index(existing.endIndex, offsetBy: -length)
            let continuationEnd = continuation.index(continuation.startIndex, offsetBy: length)
            if existing[existingStart...] == continuation[..<continuationEnd] {
                return existing + String(continuation[continuationEnd...])
            }
        }
        return existing + continuation
    }
}
