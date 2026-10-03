import Foundation

public struct TemplateEvidence: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var chapterNumber: Int
    public var location: String
    public var paraphrase: String

    public init(id: UUID = UUID(), chapterNumber: Int, location: String, paraphrase: String) {
        self.id = id
        self.chapterNumber = chapterNumber
        self.location = location
        self.paraphrase = String(paraphrase.prefix(120))
    }
}

public struct WritingTemplate: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var summary: String
    public var sourceDescription: String
    public var sourceHash: String
    public var analysisVersion: String
    public var createdAt: Date
    public var coverage: Double
    public var confidence: Double
    public var style: StyleProfile
    public var structureStrategies: [String]
    public var pacingStrategies: [String]
    public var payoffStrategies: [String]
    public var foreshadowingStrategies: [String]
    public var hookStrategies: [String]
    public var chapterConstraints: [String]
    public var recommendedPractices: [String]
    public var avoidedPractices: [String]
    public var suitableGenres: [String]
    public var evidence: [TemplateEvidence]

    public init(
        id: UUID = UUID(),
        name: String,
        summary: String,
        sourceDescription: String,
        sourceHash: String,
        analysisVersion: String = "1.0.0",
        createdAt: Date = Date(),
        coverage: Double,
        confidence: Double,
        style: StyleProfile,
        structureStrategies: [String] = [],
        pacingStrategies: [String] = [],
        payoffStrategies: [String] = [],
        foreshadowingStrategies: [String] = [],
        hookStrategies: [String] = [],
        chapterConstraints: [String] = [],
        recommendedPractices: [String] = [],
        avoidedPractices: [String] = [],
        suitableGenres: [String] = [],
        evidence: [TemplateEvidence] = []
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.sourceDescription = sourceDescription
        self.sourceHash = sourceHash
        self.analysisVersion = analysisVersion
        self.createdAt = createdAt
        self.coverage = min(1, max(0, coverage))
        self.confidence = min(1, max(0, confidence))
        self.style = style
        self.structureStrategies = structureStrategies
        self.pacingStrategies = pacingStrategies
        self.payoffStrategies = payoffStrategies
        self.foreshadowingStrategies = foreshadowingStrategies
        self.hookStrategies = hookStrategies
        self.chapterConstraints = chapterConstraints
        self.recommendedPractices = recommendedPractices
        self.avoidedPractices = avoidedPractices
        self.suitableGenres = suitableGenres
        self.evidence = Array(evidence.prefix(40))
    }
}

public struct WritingTemplateSnapshot: Codable, Hashable, Sendable {
    public var sourceTemplateID: UUID
    public var appliedAt: Date
    public var template: WritingTemplate

    public init(sourceTemplateID: UUID, appliedAt: Date = Date(), template: WritingTemplate) {
        self.sourceTemplateID = sourceTemplateID
        self.appliedAt = appliedAt
        self.template = template
    }
}

public struct ManuscriptChapterMetric: Codable, Identifiable, Hashable, Sendable {
    public var id: Int { number }
    public var number: Int
    public var title: String
    public var characterCount: Int
    public var paragraphCount: Int
    public var dialogueRatio: Double
    public var openingPattern: String
    public var endingPattern: String

    public init(number: Int, title: String, characterCount: Int, paragraphCount: Int, dialogueRatio: Double, openingPattern: String, endingPattern: String) {
        self.number = number
        self.title = title
        self.characterCount = characterCount
        self.paragraphCount = paragraphCount
        self.dialogueRatio = dialogueRatio
        self.openingPattern = openingPattern
        self.endingPattern = endingPattern
    }
}

public struct ManuscriptGraphNode: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var label: String
    public var kind: String
    public var frequency: Int

    public init(id: String, label: String, kind: String, frequency: Int) {
        self.id = id
        self.label = label
        self.kind = kind
        self.frequency = frequency
    }
}

public struct ManuscriptGraphEdge: Codable, Identifiable, Hashable, Sendable {
    public var id: String { "\(source)|\(target)" }
    public var source: String
    public var target: String
    public var relation: String
    public var weight: Int

    public init(source: String, target: String, relation: String, weight: Int) {
        self.source = source
        self.target = target
        self.relation = relation
        self.weight = weight
    }
}

public struct ManuscriptIndex: Codable, Hashable, Sendable {
    public var sourceHash: String
    public var sourceName: String
    public var analyzedCharacters: Int
    public var averageSentenceLength: Double
    public var chapterMetrics: [ManuscriptChapterMetric]
    public var nodes: [ManuscriptGraphNode]
    public var edges: [ManuscriptGraphEdge]
    public var representativeEvidence: [TemplateEvidence]
    public var estimatedSynthesisTokens: Int

    public init(sourceHash: String, sourceName: String, analyzedCharacters: Int, averageSentenceLength: Double = 0, chapterMetrics: [ManuscriptChapterMetric], nodes: [ManuscriptGraphNode], edges: [ManuscriptGraphEdge], representativeEvidence: [TemplateEvidence], estimatedSynthesisTokens: Int) {
        self.sourceHash = sourceHash
        self.sourceName = sourceName
        self.analyzedCharacters = analyzedCharacters
        self.averageSentenceLength = averageSentenceLength
        self.chapterMetrics = chapterMetrics
        self.nodes = nodes
        self.edges = edges
        self.representativeEvidence = representativeEvidence
        self.estimatedSynthesisTokens = estimatedSynthesisTokens
    }
}
