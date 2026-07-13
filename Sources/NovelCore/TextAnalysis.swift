import Foundation

public struct TextStatistics: Codable, Equatable, Sendable {
    public var characterCount: Int
    public var chineseCharacterCount: Int
    public var paragraphCount: Int
    public var sentenceCount: Int
    public var dialogueRatio: Double
    public var averageSentenceLength: Double
    public var averageParagraphLength: Double

    public init(characterCount: Int, chineseCharacterCount: Int, paragraphCount: Int, sentenceCount: Int, dialogueRatio: Double, averageSentenceLength: Double, averageParagraphLength: Double) {
        self.characterCount = characterCount
        self.chineseCharacterCount = chineseCharacterCount
        self.paragraphCount = paragraphCount
        self.sentenceCount = sentenceCount
        self.dialogueRatio = dialogueRatio
        self.averageSentenceLength = averageSentenceLength
        self.averageParagraphLength = averageParagraphLength
    }
}

public enum TextAnalyzer {
    public static func statistics(for text: String) -> TextStatistics {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let paragraphs = trimmed
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let sentences = trimmed.split(whereSeparator: { "。！？!?".contains($0) })
        let chineseCount = trimmed.unicodeScalars.reduce(into: 0) { count, scalar in
            if (0x4E00...0x9FFF).contains(scalar.value) ||
                (0x3400...0x4DBF).contains(scalar.value) ||
                (0x20000...0x2A6DF).contains(scalar.value) {
                count += 1
            }
        }
        let quoteCharacters = trimmed.filter { "“”「」『』\"".contains($0) }.count
        let dialogueRatio = trimmed.isEmpty ? 0 : min(1, Double(quoteCharacters) / Double(max(trimmed.count, 1)) * 12)

        return TextStatistics(
            characterCount: trimmed.count,
            chineseCharacterCount: chineseCount,
            paragraphCount: paragraphs.count,
            sentenceCount: sentences.count,
            dialogueRatio: dialogueRatio,
            averageSentenceLength: sentences.isEmpty ? 0 : Double(trimmed.count) / Double(sentences.count),
            averageParagraphLength: paragraphs.isEmpty ? 0 : Double(trimmed.count) / Double(paragraphs.count)
        )
    }

    public static func styleProfile(from sample: String, perspective: NarrativePerspective) -> StyleProfile {
        let stats = statistics(for: sample)
        return StyleProfile(
            averageSentenceLength: stats.averageSentenceLength,
            dialogueRatio: stats.dialogueRatio,
            paragraphLength: stats.averageParagraphLength,
            perspective: perspective
        )
    }

    public static func normalizedParagraphs(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public static func ngrams(_ text: String, size: Int = 4) -> Set<String> {
        let normalized = text.filter { !$0.isWhitespace && !$0.isPunctuation }
        guard size > 0, normalized.count >= size else {
            return normalized.isEmpty ? [] : [normalized]
        }
        var result = Set<String>()
        var start = normalized.startIndex
        while let end = normalized.index(start, offsetBy: size, limitedBy: normalized.endIndex) {
            result.insert(String(normalized[start..<end]))
            guard start < normalized.endIndex else { break }
            start = normalized.index(after: start)
            if normalized.distance(from: start, to: normalized.endIndex) < size { break }
        }
        return result
    }

    public static func jaccardSimilarity(_ lhs: String, _ rhs: String, ngramSize: Int = 4) -> Double {
        let left = ngrams(lhs, size: ngramSize)
        let right = ngrams(rhs, size: ngramSize)
        guard !left.isEmpty || !right.isEmpty else { return 1 }
        return Double(left.intersection(right).count) / Double(left.union(right).count)
    }
}

public struct LocalQualityScanner: Sendable {
    public init() {}

    public func scan(
        text: String,
        targetWords: Int,
        bannedTerms: [String] = [],
        referenceSamples: [String] = []
    ) -> [ReviewIssue] {
        var issues: [ReviewIssue] = []
        let stats = TextAnalyzer.statistics(for: text)

        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(ReviewIssue(severity: .critical, dimension: .readability, title: "章节正文为空"))
            return issues
        }

        let lowerBound = Int(Double(targetWords) * 0.75)
        let upperBound = Int(Double(targetWords) * 1.35)
        if stats.chineseCharacterCount < lowerBound || stats.chineseCharacterCount > upperBound {
            issues.append(ReviewIssue(
                severity: .medium,
                dimension: .pacing,
                title: "章节长度偏离目标",
                evidence: "当前约 \(stats.chineseCharacterCount) 个汉字，目标约 \(targetWords) 字。",
                suggestion: "检查是否缺少关键场景，或是否存在可压缩的重复描写。"
            ))
        }

        let metaPhrases = ["作为AI", "作为 AI", "以下是", "希望这个章节", "我将为你", "当然可以"]
        for phrase in metaPhrases where text.localizedCaseInsensitiveContains(phrase) {
            issues.append(ReviewIssue(severity: .high, dimension: .prose, title: "出现模型元话语", evidence: phrase, suggestion: "删除脱离小说叙事的说明。"))
        }

        for term in bannedTerms where !term.isEmpty && text.contains(term) {
            issues.append(ReviewIssue(severity: .high, dimension: .readability, title: "命中禁用词", evidence: term, suggestion: "根据作品限制替换或删除。"))
        }

        let paragraphs = TextAnalyzer.normalizedParagraphs(text)
        let grouped = Dictionary(grouping: paragraphs, by: { $0 })
        for (paragraph, occurrences) in grouped where paragraph.count >= 20 && occurrences.count > 1 {
            issues.append(ReviewIssue(severity: .high, dimension: .originality, title: "重复段落", evidence: String(paragraph.prefix(100)), suggestion: "删除重复内容或重新组织表达。"))
        }

        let sentences = text.split(whereSeparator: { "。！？!?".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 12 }
        let sentenceGroups = Dictionary(grouping: sentences, by: { $0 })
        for (sentence, occurrences) in sentenceGroups where occurrences.count > 1 {
            issues.append(ReviewIssue(severity: .medium, dimension: .prose, title: "重复句子", evidence: String(sentence.prefix(100)), suggestion: "检查是否为模型重复输出，或改写为不同信息推进。"))
        }

        let punctuationPatterns = ["。。", "！！", "？？", "，，", "……。", "，，"]
        for pattern in punctuationPatterns where text.contains(pattern) {
            issues.append(ReviewIssue(severity: .low, dimension: .readability, title: "标点可能异常", evidence: pattern, suggestion: "检查标点是否符合正文语气。"))
        }

        for sample in referenceSamples where sample.count >= 100 {
            let similarity = TextAnalyzer.jaccardSimilarity(text, sample, ngramSize: 8)
            if similarity >= 0.28 {
                issues.append(ReviewIssue(
                    severity: .high,
                    dimension: .originality,
                    title: "与参考样章存在较高片段重合",
                    evidence: "8 字符片段相似度约 \(Int(similarity * 100))%。",
                    suggestion: "只保留抽象风格指标，重新表达具体句段。"
                ))
            }
        }

        return issues
    }
}
