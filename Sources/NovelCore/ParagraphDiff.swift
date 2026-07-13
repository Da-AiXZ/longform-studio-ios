import Foundation

public enum ParagraphDiffKind: String, Codable, Hashable, Sendable {
    case unchanged
    case inserted
    case deleted
}

public struct ParagraphDiffEntry: Identifiable, Equatable, Sendable {
    public var id: Int
    public var kind: ParagraphDiffKind
    public var text: String

    public init(id: Int, kind: ParagraphDiffKind, text: String) {
        self.id = id
        self.kind = kind
        self.text = text
    }
}

public enum ParagraphDiff {
    public static func compare(old: String, new: String) -> [ParagraphDiffEntry] {
        let left = TextAnalyzer.normalizedParagraphs(old)
        let right = TextAnalyzer.normalizedParagraphs(new)
        let rowCount = left.count + 1
        let columnCount = right.count + 1
        var table = Array(repeating: Array(repeating: 0, count: columnCount), count: rowCount)

        if !left.isEmpty && !right.isEmpty {
            for i in stride(from: left.count - 1, through: 0, by: -1) {
                for j in stride(from: right.count - 1, through: 0, by: -1) {
                    table[i][j] = left[i] == right[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                }
            }
        }

        var result: [ParagraphDiffEntry] = []
        var i = 0
        var j = 0
        var id = 0
        while i < left.count || j < right.count {
            if i < left.count && j < right.count && left[i] == right[j] {
                result.append(ParagraphDiffEntry(id: id, kind: .unchanged, text: left[i]))
                i += 1
                j += 1
            } else if j < right.count && (i == left.count || table[i][j + 1] >= table[i + 1][j]) {
                result.append(ParagraphDiffEntry(id: id, kind: .inserted, text: right[j]))
                j += 1
            } else if i < left.count {
                result.append(ParagraphDiffEntry(id: id, kind: .deleted, text: left[i]))
                i += 1
            }
            id += 1
        }
        return result
    }
}
