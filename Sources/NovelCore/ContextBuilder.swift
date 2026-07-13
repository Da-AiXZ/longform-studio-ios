import Foundation

public enum ContextCategory: String, Codable, Hashable, Sendable {
    case instruction
    case storyBible
    case outline
    case entity
    case continuity
    case previousChapter
    case earlierSummary
    case retrievedPassage
}

public struct ContextItem: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var category: ContextCategory
    public var title: String
    public var text: String
    public var priority: Int
    public var relevance: Double
    public var required: Bool

    public init(id: String, category: ContextCategory, title: String, text: String, priority: Int, relevance: Double = 0, required: Bool = false) {
        self.id = id
        self.category = category
        self.title = title
        self.text = text
        self.priority = priority
        self.relevance = relevance
        self.required = required
    }

    public var estimatedTokens: Int { TokenEstimator.estimate(text) + 8 }
}

public struct ContextSelection: Equatable, Sendable {
    public var items: [ContextItem]
    public var estimatedInputTokens: Int
    public var availableInputTokens: Int
    public var droppedItemIDs: [String]

    public init(items: [ContextItem], estimatedInputTokens: Int, availableInputTokens: Int, droppedItemIDs: [String]) {
        self.items = items
        self.estimatedInputTokens = estimatedInputTokens
        self.availableInputTokens = availableInputTokens
        self.droppedItemIDs = droppedItemIDs
    }
}

public enum TokenEstimator {
    public static func estimate(_ text: String) -> Int {
        let chinese = text.unicodeScalars.reduce(into: 0) { count, scalar in
            if (0x3400...0x9FFF).contains(scalar.value) { count += 1 }
        }
        let nonChinese = max(0, text.count - chinese)
        return max(1, Int(ceil(Double(chinese) / 1.45 + Double(nonChinese) / 3.8)))
    }
}

public enum ContextBuilder {
    public static func select(
        from candidates: [ContextItem],
        contextLimit: Int,
        outputReserve: Int,
        safetyRatio: Double = 0.15
    ) -> ContextSelection {
        let safeLimit = Int(Double(contextLimit) * (1 - min(0.5, max(0, safetyRatio))))
        let available = max(0, safeLimit - outputReserve)
        let sorted = candidates.sorted {
            if $0.required != $1.required { return $0.required && !$1.required }
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            if $0.relevance != $1.relevance { return $0.relevance > $1.relevance }
            return $0.id < $1.id
        }

        var selected: [ContextItem] = []
        var dropped: [String] = []
        var used = 0
        for item in sorted {
            if used + item.estimatedTokens <= available {
                selected.append(item)
                used += item.estimatedTokens
            } else {
                dropped.append(item.id)
            }
        }

        return ContextSelection(
            items: selected,
            estimatedInputTokens: used,
            availableInputTokens: available,
            droppedItemIDs: dropped
        )
    }

    public static func relevance(of candidate: String, to query: String) -> Double {
        TextAnalyzer.jaccardSimilarity(candidate, query, ngramSize: 3)
    }
}
