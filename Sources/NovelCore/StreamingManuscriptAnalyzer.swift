import Foundation

public struct ManuscriptAnalysisProgress: Equatable, Sendable {
    public var processedBytes: Int64
    public var totalBytes: Int64
    public var chaptersFound: Int

    public init(processedBytes: Int64, totalBytes: Int64, chaptersFound: Int) {
        self.processedBytes = processedBytes
        self.totalBytes = totalBytes
        self.chaptersFound = chaptersFound
    }

    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(processedBytes) / Double(totalBytes)))
    }
}

public enum ManuscriptAnalysisError: LocalizedError {
    case unsupportedEncoding
    case emptyDocument

    public var errorDescription: String? {
        switch self {
        case .unsupportedEncoding: return "仅支持 UTF-8 与 UTF-16 文本。"
        case .emptyDocument: return "上传的小说文件没有可分析正文。"
        }
    }
}

public struct StreamingManuscriptAnalyzer: Sendable {
    public static let analysisVersion = "1.0.0"
    public var chunkSize: Int
    public var maximumTerms: Int
    public var synthesisTokenLimit: Int

    public init(chunkSize: Int = 64 * 1_024, maximumTerms: Int = 5_000, synthesisTokenLimit: Int = 80_000) {
        self.chunkSize = max(4, chunkSize)
        self.maximumTerms = max(200, maximumTerms)
        self.synthesisTokenLimit = max(4_096, synthesisTokenLimit)
    }

    public func analyze(
        url: URL,
        progress: (@Sendable (ManuscriptAnalysisProgress) -> Void)? = nil
    ) async throws -> ManuscriptIndex {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        let totalBytes = Int64(values.fileSize ?? 0)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let prefix = try handle.read(upToCount: 4) ?? Data()
        try handle.seek(toOffset: 0)
        var decoder = try IncrementalTextDecoder(prefix: prefix)
        var collector = ManuscriptCollector(maximumTerms: maximumTerms)
        var processed: Int64 = 0
        var lineBuffer = ""
        var hash: UInt64 = 14_695_981_039_346_656_037

        while let data = try handle.read(upToCount: chunkSize), !data.isEmpty {
            try Task.checkCancellation()
            processed += Int64(data.count)
            for byte in data {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            let text = try decoder.decode(data, final: false)
            consume(text: text, lineBuffer: &lineBuffer, collector: &collector)
            progress?(ManuscriptAnalysisProgress(processedBytes: processed, totalBytes: totalBytes, chaptersFound: collector.chapterCount))
            await Task.yield()
        }

        let tail = try decoder.decode(Data(), final: true)
        consume(text: tail, lineBuffer: &lineBuffer, collector: &collector)
        if !lineBuffer.isEmpty { collector.consume(line: lineBuffer) }
        let index = try collector.finish(sourceName: url.deletingPathExtension().lastPathComponent, sourceHash: String(hash, radix: 16), synthesisTokenLimit: synthesisTokenLimit)
        progress?(ManuscriptAnalysisProgress(processedBytes: totalBytes, totalBytes: totalBytes, chaptersFound: index.chapterMetrics.count))
        return index
    }

    public func makeLocalTemplate(from index: ManuscriptIndex, perspective: NarrativePerspective = .thirdPersonLimited) -> WritingTemplate {
        let metrics = index.chapterMetrics
        let averageLength = metrics.isEmpty ? 0 : Double(metrics.map(\.characterCount).reduce(0, +)) / Double(metrics.count)
        let averageParagraphs = metrics.isEmpty ? 0 : Double(metrics.map(\.paragraphCount).reduce(0, +)) / Double(metrics.count)
        let dialogue = metrics.isEmpty ? 0 : metrics.map(\.dialogueRatio).reduce(0, +) / Double(metrics.count)
        let averageParagraphLength = averageParagraphs > 0 ? averageLength / averageParagraphs : 0
        let style = StyleProfile(
            averageSentenceLength: index.averageSentenceLength,
            dialogueRatio: dialogue,
            paragraphLength: averageParagraphLength,
            perspective: perspective,
            sourceDescription: "长篇本地分析：\(index.sourceName)（不保存原文）"
        )
        let opening = mostCommon(metrics.map(\.openingPattern))
        let ending = mostCommon(metrics.map(\.endingPattern))
        return WritingTemplate(
            name: "\(index.sourceName) · 写作策略",
            summary: "基于 \(metrics.count) 章、约 \(index.analyzedCharacters) 字的本地全量统计生成；语义策略可继续由 AI 在 Token 上限内补充。",
            sourceDescription: index.sourceName,
            sourceHash: index.sourceHash,
            analysisVersion: Self.analysisVersion,
            coverage: index.analyzedCharacters > 0 ? 1 : 0,
            confidence: metrics.count >= 20 ? 0.75 : 0.5,
            style: style,
            structureStrategies: ["单章平均约 \(Int(averageLength)) 字，保持清晰的场景推进与章末承接。"],
            pacingStrategies: ["每章平均约 \(Int(averageParagraphs)) 个有效段落。"],
            hookStrategies: ending.isEmpty ? [] : ["常见章末结构：\(ending)。"],
            chapterConstraints: opening.isEmpty ? [] : ["常见开篇结构：\(opening)。"],
            recommendedPractices: ["只应用抽象结构和统计特征，不复用来源文本的具体表达。"],
            avoidedPractices: ["避免连续复制来源作品的句式、专名和独特情节组合。"],
            evidence: index.representativeEvidence
        )
    }

    private func consume(text: String, lineBuffer: inout String, collector: inout ManuscriptCollector) {
        lineBuffer += text
        lineBuffer = lineBuffer
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        while let newline = lineBuffer.firstIndex(of: "\n") {
            let line = String(lineBuffer[..<newline])
            let next = lineBuffer.index(after: newline)
            lineBuffer = String(lineBuffer[next...])
            collector.consume(line: line)
        }

        // Malformed files occasionally contain no newlines. Bound retained memory while
        // still accumulating their statistics as a single chapter.
        if lineBuffer.count > chunkSize * 4 {
            collector.consume(line: String(lineBuffer.prefix(chunkSize * 2)))
            lineBuffer.removeFirst(min(lineBuffer.count, chunkSize * 2))
        }
    }

    private func mostCommon(_ values: [String]) -> String {
        Dictionary(grouping: values.filter { !$0.isEmpty }, by: { $0 })
            .max { $0.value.count < $1.value.count }?.key ?? ""
    }
}

private struct IncrementalTextDecoder {
    enum Encoding: Equatable { case utf8, utf16LittleEndian, utf16BigEndian }
    private var encoding: Encoding
    private var carry = Data()
    private var shouldDropBOM: Bool

    init(prefix: Data) throws {
        if prefix.starts(with: [0xFF, 0xFE]) {
            encoding = .utf16LittleEndian
            shouldDropBOM = true
        } else if prefix.starts(with: [0xFE, 0xFF]) {
            encoding = .utf16BigEndian
            shouldDropBOM = true
        } else if prefix.starts(with: [0xEF, 0xBB, 0xBF]) {
            encoding = .utf8
            shouldDropBOM = true
        } else if prefix.count >= 4, (prefix[1] == 0 || prefix[3] == 0) {
            encoding = .utf16LittleEndian
            shouldDropBOM = false
        } else if prefix.count >= 4, (prefix[0] == 0 || prefix[2] == 0) {
            encoding = .utf16BigEndian
            shouldDropBOM = false
        } else {
            encoding = .utf8
            shouldDropBOM = false
        }
    }

    mutating func decode(_ data: Data, final: Bool) throws -> String {
        carry.append(data)
        if shouldDropBOM {
            let count = encoding == .utf8 ? 3 : 2
            if carry.count < count, !final { return "" }
            if carry.count >= count { carry.removeFirst(count) }
            shouldDropBOM = false
        }

        if final {
            guard let decoded = String(data: carry, encoding: stringEncoding) else {
                throw ManuscriptAnalysisError.unsupportedEncoding
            }
            carry.removeAll(keepingCapacity: false)
            return decoded
        }

        let retainedCounts: [Int]
        switch encoding {
        case .utf8:
            retainedCounts = Array(0...min(3, carry.count))
        case .utf16LittleEndian, .utf16BigEndian:
            let partialCodeUnit = carry.count % 2
            retainedCounts = [partialCodeUnit, partialCodeUnit + 2].filter { $0 <= carry.count }
        }
        for retained in retainedCounts {
            let end = carry.count - retained
            let candidate = carry.prefix(end)
            if let text = String(data: candidate, encoding: stringEncoding) {
                carry = Data(carry.suffix(retained))
                return text
            }
        }
        throw ManuscriptAnalysisError.unsupportedEncoding
    }

    private var stringEncoding: String.Encoding {
        switch encoding {
        case .utf8: return .utf8
        case .utf16LittleEndian: return .utf16LittleEndian
        case .utf16BigEndian: return .utf16BigEndian
        }
    }
}

private struct ManuscriptCollector {
    private struct ChapterAccumulator {
        var number: Int
        var title: String
        var characterCount = 0
        var paragraphCount = 0
        var quoteCount = 0
        var opening = ""
        var ending = ""
        var terms = Set<String>()
    }

    private let maximumTerms: Int
    private var current = ChapterAccumulator(number: 1, title: "第1章 导入正文")
    private(set) var metrics: [ManuscriptChapterMetric] = []
    private var chapterTerms: [Set<String>] = []
    private var termFrequency: [String: Int] = [:]
    private var evidence: [TemplateEvidence] = []
    private var totalCharacters = 0
    private var totalSentences = 0

    init(maximumTerms: Int) { self.maximumTerms = maximumTerms }
    var chapterCount: Int { metrics.count + (current.characterCount > 0 ? 1 : 0) }

    mutating func consume(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if isHeading(trimmed) {
            closeChapter()
            current = ChapterAccumulator(number: metrics.count + 1, title: String(trimmed.prefix(80)))
            return
        }

        current.paragraphCount += 1
        current.characterCount += trimmed.count
        totalCharacters += trimmed.count
        totalSentences += max(1, trimmed.filter { "。！？!?".contains($0) }.count)
        current.quoteCount += trimmed.filter { "“”「」『』\"".contains($0) }.count
        if current.opening.count < 80 {
            current.opening += String(trimmed.prefix(80 - current.opening.count))
        }
        current.ending = String((current.ending + trimmed).suffix(80))

        let terms = extractedTerms(from: trimmed)
        if current.terms.count < 200 {
            current.terms.formUnion(terms.prefix(200 - current.terms.count))
        }
        for term in terms.prefix(80) {
            if termFrequency[term] != nil || termFrequency.count < maximumTerms {
                termFrequency[term, default: 0] += 1
            }
        }
    }

    mutating func finish(sourceName: String, sourceHash: String, synthesisTokenLimit: Int) throws -> ManuscriptIndex {
        closeChapter()
        guard totalCharacters > 0, !metrics.isEmpty else { throw ManuscriptAnalysisError.emptyDocument }
        let topTerms = termFrequency.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key < $1.key
        }.prefix(80)
        let selected = Set(topTerms.map(\.key))
        var nodes = topTerms.map { ManuscriptGraphNode(id: "term-\(stableIdentifier($0.key))", label: $0.key, kind: "concept", frequency: $0.value) }
        var edgeWeights: [String: Int] = [:]
        for terms in chapterTerms {
            let values = Array(terms.intersection(selected)).sorted().prefix(12)
            for index in values.indices {
                for other in values.indices where other > index {
                    edgeWeights["\(values[index])|\(values[other])", default: 0] += 1
                }
            }
        }
        var edges = edgeWeights.sorted { $0.value > $1.value }.prefix(200).map { pair -> ManuscriptGraphEdge in
            let values = pair.key.split(separator: "|", maxSplits: 1).map(String.init)
            return ManuscriptGraphEdge(source: "term-\(stableIdentifier(values[0]))", target: "term-\(stableIdentifier(values[1]))", relation: "coOccurrence", weight: pair.value)
        }
        let chapterIndices = sampledChapterIndices(limit: 500)
        var structureNodes: [String: ManuscriptGraphNode] = [:]
        var previousChapterID: String?
        for index in chapterIndices {
            let metric = metrics[index]
            let chapterID = "chapter-\(metric.number)"
            nodes.append(ManuscriptGraphNode(id: chapterID, label: metric.title, kind: "chapter", frequency: 1))
            if let previousChapterID {
                edges.append(ManuscriptGraphEdge(source: previousChapterID, target: chapterID, relation: "precedes", weight: 1))
            }
            previousChapterID = chapterID

            for (relation, pattern) in [("opensWith", metric.openingPattern), ("endsWith", metric.endingPattern)] where !pattern.isEmpty {
                let structureID = "structure-\(stableIdentifier(pattern))"
                structureNodes[structureID] = ManuscriptGraphNode(id: structureID, label: pattern, kind: "structure", frequency: (structureNodes[structureID]?.frequency ?? 0) + 1)
                edges.append(ManuscriptGraphEdge(source: chapterID, target: structureID, relation: relation, weight: 1))
            }

            let concepts = chapterTerms[index].intersection(selected).sorted {
                let left = termFrequency[$0] ?? 0
                let right = termFrequency[$1] ?? 0
                return left == right ? $0 < $1 : left > right
            }.prefix(4)
            for concept in concepts {
                edges.append(ManuscriptGraphEdge(source: chapterID, target: "term-\(stableIdentifier(concept))", relation: "mentions", weight: 1))
            }
        }
        nodes.append(contentsOf: structureNodes.values.sorted { $0.id < $1.id })
        let estimated = min(synthesisTokenLimit, max(1_024, metrics.count * 24 + nodes.count * 12 + evidence.count * 40))
        return ManuscriptIndex(
            sourceHash: sourceHash,
            sourceName: sourceName,
            analyzedCharacters: totalCharacters,
            averageSentenceLength: totalSentences == 0 ? 0 : Double(totalCharacters) / Double(totalSentences),
            chapterMetrics: metrics,
            nodes: nodes,
            edges: edges,
            representativeEvidence: evidence,
            estimatedSynthesisTokens: estimated
        )
    }

    private mutating func closeChapter() {
        guard current.characterCount > 0 else { return }
        let ratio = min(1, Double(current.quoteCount) / Double(max(1, current.characterCount)) * 12)
        let openingPattern = classify(current.opening, ending: false)
        let endingPattern = classify(current.ending, ending: true)
        metrics.append(ManuscriptChapterMetric(number: current.number, title: current.title, characterCount: current.characterCount, paragraphCount: current.paragraphCount, dialogueRatio: ratio, openingPattern: openingPattern, endingPattern: endingPattern))
        chapterTerms.append(current.terms)
        if evidence.count < 40, metrics.count == 1 || metrics.count % 10 == 0 {
            evidence.append(TemplateEvidence(chapterNumber: current.number, location: "章末结构", paraphrase: endingPattern))
        }
    }

    private func isHeading(_ value: String) -> Bool {
        guard value.count <= 80 else { return false }
        if value.hasPrefix("# ") || value.hasPrefix("## ") { return true }
        guard value.hasPrefix("第"), let chapter = value.firstIndex(of: "章") else { return false }
        return value.distance(from: value.startIndex, to: chapter) <= 12
    }

    private func classify(_ text: String, ending: Bool) -> String {
        if text.contains("？") || text.contains("?") { return ending ? "以疑问或未知信息形成悬念" : "以疑问切入场景" }
        if text.contains("！") || text.contains("!") { return ending ? "以冲突或情绪峰值收束" : "以动作或强冲突开场" }
        if text.contains("“") || text.contains("\"") { return ending ? "以人物对白留下下一步信息" : "以人物对白快速入场" }
        let actionTerms = ["冲", "杀", "推", "撞", "追", "逃", "落", "响"]
        if actionTerms.contains(where: text.contains) { return ending ? "以动作变化连接下一章" : "以动作事件开场" }
        return ending ? "以叙述状态变化收束" : "以环境或状态铺陈开场"
    }

    private func extractedTerms(from text: String) -> [String] {
        let characters = text.filter { character in
            character.unicodeScalars.allSatisfy { (0x3400...0x9FFF).contains($0.value) }
        }
        guard characters.count >= 2 else { return [] }
        var result: [String] = []
        var index = characters.startIndex
        while let end = characters.index(index, offsetBy: 2, limitedBy: characters.endIndex) {
            let term = String(characters[index..<end])
            if !Self.stopTerms.contains(term) { result.append(term) }
            index = characters.index(after: index)
            if characters.distance(from: index, to: characters.endIndex) < 2 { break }
        }
        return result
    }

    private func stableIdentifier(_ text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 { hash ^= UInt64(byte); hash &*= 1_099_511_628_211 }
        return String(hash, radix: 16)
    }

    private func sampledChapterIndices(limit: Int) -> [Int] {
        guard !metrics.isEmpty else { return [] }
        if metrics.count <= limit { return Array(metrics.indices) }
        let stride = Double(metrics.count - 1) / Double(limit - 1)
        return (0..<limit).map { min(metrics.count - 1, Int((Double($0) * stride).rounded())) }
    }

    private static let stopTerms: Set<String> = ["一个", "这个", "那个", "自己", "什么", "没有", "不是", "就是", "已经", "还是", "只是", "可以", "知道", "他们", "我们", "你们", "因为", "所以"]
}
