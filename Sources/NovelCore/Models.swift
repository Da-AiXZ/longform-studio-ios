import Foundation

public enum PublishingPlatform: String, Codable, CaseIterable, Hashable, Sendable {
    case qidian
    case fanqie

    public var displayName: String {
        switch self {
        case .qidian: return "起点男频"
        case .fanqie: return "番茄男频"
        }
    }
}

public enum NarrativePerspective: String, Codable, CaseIterable, Hashable, Sendable {
    case thirdPersonLimited
    case firstPerson
    case omniscient

    public var displayName: String {
        switch self {
        case .thirdPersonLimited: return "第三人称限知"
        case .firstPerson: return "第一人称"
        case .omniscient: return "第三人称全知"
        }
    }
}

public enum ChapterStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case planned
    case drafting
    case reviewing
    case approved
}

public enum VersionSource: String, Codable, Hashable, Sendable {
    case manual
    case generated
    case rewritten
    case imported
}

public enum FactStatus: String, Codable, Hashable, Sendable {
    case candidate
    case accepted
    case rejected
}

public enum GenerationStatus: String, Codable, Hashable, Sendable {
    case running
    case completed
    case failed
    case cancelled
}

public enum AIRole: String, Codable, CaseIterable, Hashable, Sendable {
    case planner
    case writer
    case reviewer
    case rewriter
    case memoryExtractor

    public var displayName: String {
        switch self {
        case .planner: return "策划"
        case .writer: return "写作"
        case .reviewer: return "审稿"
        case .rewriter: return "改稿"
        case .memoryExtractor: return "记忆提取"
        }
    }
}

public enum ReviewKind: String, Codable, CaseIterable, Hashable, Sendable {
    case plot
    case continuity
    case prose
    case platform
    case regression

    public var displayName: String {
        switch self {
        case .plot: return "情节编辑"
        case .continuity: return "连续性编辑"
        case .prose: return "文字编辑"
        case .platform: return "平台编辑"
        case .regression: return "跨章回归"
        }
    }
}

public enum ReviewSeverity: String, Codable, CaseIterable, Hashable, Sendable {
    case info
    case low
    case medium
    case high
    case critical

    public var rank: Int {
        switch self {
        case .info: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        case .critical: return 4
        }
    }
}

public enum QualityDimension: String, Codable, CaseIterable, Hashable, Sendable {
    case plotCausality
    case continuity
    case character
    case longTermStructure
    case prose
    case hookPayoff
    case originality
    case pacing
    case conflictEmotion
    case readability

    public var displayName: String {
        switch self {
        case .plotCausality: return "情节因果"
        case .continuity: return "世界与连续性"
        case .character: return "人物"
        case .longTermStructure: return "长线结构与伏笔"
        case .prose: return "文风"
        case .hookPayoff: return "兑现与钩子"
        case .originality: return "原创性"
        case .pacing: return "节奏与事件密度"
        case .conflictEmotion: return "冲突与情绪"
        case .readability: return "可读性与自然度"
        }
    }
}

public struct NovelProject: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var schemaVersion: Int
    public var planRevision: Int
    public var title: String
    public var platform: PublishingPlatform
    public var genre: String
    public var sellingPoint: String
    public var targetWordCount: Int
    public var protagonistGoal: String
    public var restrictedContent: [String]
    public var perspective: NarrativePerspective
    public var targetChapterWords: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        schemaVersion: Int = 2,
        planRevision: Int = 0,
        title: String,
        platform: PublishingPlatform,
        genre: String,
        sellingPoint: String,
        targetWordCount: Int,
        protagonistGoal: String,
        restrictedContent: [String] = [],
        perspective: NarrativePerspective = .thirdPersonLimited,
        targetChapterWords: Int = 2_500,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.planRevision = planRevision
        self.title = title
        self.platform = platform
        self.genre = genre
        self.sellingPoint = sellingPoint
        self.targetWordCount = targetWordCount
        self.protagonistGoal = protagonistGoal
        self.restrictedContent = restrictedContent
        self.perspective = perspective
        self.targetChapterWords = targetChapterWords
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, schemaVersion, planRevision, title, platform, genre, sellingPoint, targetWordCount
        case protagonistGoal, restrictedContent, perspective, targetChapterWords, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        planRevision = try container.decodeIfPresent(Int.self, forKey: .planRevision) ?? 0
        title = try container.decode(String.self, forKey: .title)
        platform = try container.decode(PublishingPlatform.self, forKey: .platform)
        genre = try container.decodeIfPresent(String.self, forKey: .genre) ?? "待确认"
        sellingPoint = try container.decodeIfPresent(String.self, forKey: .sellingPoint) ?? ""
        targetWordCount = try container.decodeIfPresent(Int.self, forKey: .targetWordCount) ?? 1_000_000
        protagonistGoal = try container.decodeIfPresent(String.self, forKey: .protagonistGoal) ?? ""
        restrictedContent = try container.decodeIfPresent([String].self, forKey: .restrictedContent) ?? []
        perspective = try container.decodeIfPresent(NarrativePerspective.self, forKey: .perspective) ?? .thirdPersonLimited
        targetChapterWords = try container.decodeIfPresent(Int.self, forKey: .targetChapterWords) ?? 2_500
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}

public struct StoryBible: Codable, Hashable, Sendable {
    public var premise: String
    public var themes: [String]
    public var centralConflict: String
    public var endingPromise: String
    public var styleGuide: String
    public var forbiddenPatterns: [String]

    public init(
        premise: String = "",
        themes: [String] = [],
        centralConflict: String = "",
        endingPromise: String = "",
        styleGuide: String = "",
        forbiddenPatterns: [String] = []
    ) {
        self.premise = premise
        self.themes = themes
        self.centralConflict = centralConflict
        self.endingPromise = endingPromise
        self.styleGuide = styleGuide
        self.forbiddenPatterns = forbiddenPatterns
    }
}

public struct Character: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var role: String
    public var desire: String
    public var fear: String
    public var flaw: String
    public var arc: String
    public var voice: String
    public var currentState: String

    public init(id: UUID = UUID(), name: String, role: String = "", desire: String = "", fear: String = "", flaw: String = "", arc: String = "", voice: String = "", currentState: String = "") {
        self.id = id
        self.name = name
        self.role = role
        self.desire = desire
        self.fear = fear
        self.flaw = flaw
        self.arc = arc
        self.voice = voice
        self.currentState = currentState
    }
}

public struct WorldRule: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var category: String
    public var title: String
    public var detail: String
    public var immutable: Bool

    public init(id: UUID = UUID(), category: String, title: String, detail: String, immutable: Bool = true) {
        self.id = id
        self.category = category
        self.title = title
        self.detail = detail
        self.immutable = immutable
    }
}

public struct TimelineEvent: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var order: Int
    public var timeLabel: String
    public var event: String
    public var relatedEntityIDs: [UUID]

    public init(id: UUID = UUID(), order: Int, timeLabel: String, event: String, relatedEntityIDs: [UUID] = []) {
        self.id = id
        self.order = order
        self.timeLabel = timeLabel
        self.event = event
        self.relatedEntityIDs = relatedEntityIDs
    }
}

public struct Foreshadowing: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var setup: String
    public var intendedPayoff: String
    public var setupChapter: Int?
    public var payoffChapter: Int?
    public var resolved: Bool

    public init(id: UUID = UUID(), title: String, setup: String, intendedPayoff: String, setupChapter: Int? = nil, payoffChapter: Int? = nil, resolved: Bool = false) {
        self.id = id
        self.title = title
        self.setup = setup
        self.intendedPayoff = intendedPayoff
        self.setupChapter = setupChapter
        self.payoffChapter = payoffChapter
        self.resolved = resolved
    }
}

public struct VolumeOutline: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var number: Int
    public var title: String
    public var goal: String
    public var climax: String
    public var resolution: String

    public init(id: UUID = UUID(), number: Int, title: String, goal: String = "", climax: String = "", resolution: String = "") {
        self.id = id
        self.number = number
        self.title = title
        self.goal = goal
        self.climax = climax
        self.resolution = resolution
    }
}

public struct ChapterCard: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var volumeID: UUID?
    public var number: Int
    public var title: String
    public var goal: String
    public var conflict: String
    public var turn: String
    public var hook: String
    public var summary: String
    public var linkedEntityIDs: [UUID]
    public var status: ChapterStatus
    public var activeVersionID: UUID?
    public var versionIDs: [UUID]
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        volumeID: UUID? = nil,
        number: Int,
        title: String,
        goal: String = "",
        conflict: String = "",
        turn: String = "",
        hook: String = "",
        summary: String = "",
        linkedEntityIDs: [UUID] = [],
        status: ChapterStatus = .planned,
        activeVersionID: UUID? = nil,
        versionIDs: [UUID] = [],
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.volumeID = volumeID
        self.number = number
        self.title = title
        self.goal = goal
        self.conflict = conflict
        self.turn = turn
        self.hook = hook
        self.summary = summary
        self.linkedEntityIDs = linkedEntityIDs
        self.status = status
        self.activeVersionID = activeVersionID
        self.versionIDs = versionIDs
        self.updatedAt = updatedAt
    }
}

public struct ChapterVersion: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var chapterID: UUID
    public var createdAt: Date
    public var source: VersionSource
    public var body: String
    public var isBodyLoaded: Bool
    public var characterCount: Int
    public var manualEditCharacters: Int
    public var modelProfileID: UUID?
    public var generationRecordID: UUID?
    public var approvedAt: Date?
    public var note: String

    public init(
        id: UUID = UUID(),
        chapterID: UUID,
        createdAt: Date = Date(),
        source: VersionSource,
        body: String,
        isBodyLoaded: Bool = true,
        characterCount: Int? = nil,
        manualEditCharacters: Int = 0,
        modelProfileID: UUID? = nil,
        generationRecordID: UUID? = nil,
        approvedAt: Date? = nil,
        note: String = ""
    ) {
        self.id = id
        self.chapterID = chapterID
        self.createdAt = createdAt
        self.source = source
        self.body = body
        self.isBodyLoaded = isBodyLoaded
        self.characterCount = characterCount ?? TextAnalyzer.statistics(for: body).chineseCharacterCount
        self.manualEditCharacters = manualEditCharacters
        self.modelProfileID = modelProfileID
        self.generationRecordID = generationRecordID
        self.approvedAt = approvedAt
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case id, chapterID, createdAt, source, body, isBodyLoaded, characterCount, manualEditCharacters
        case modelProfileID, generationRecordID, approvedAt, note
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        chapterID = try container.decode(UUID.self, forKey: .chapterID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        source = try container.decode(VersionSource.self, forKey: .source)
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        isBodyLoaded = try container.decodeIfPresent(Bool.self, forKey: .isBodyLoaded) ?? true
        characterCount = try container.decodeIfPresent(Int.self, forKey: .characterCount) ?? TextAnalyzer.statistics(for: body).chineseCharacterCount
        manualEditCharacters = try container.decodeIfPresent(Int.self, forKey: .manualEditCharacters) ?? 0
        modelProfileID = try container.decodeIfPresent(UUID.self, forKey: .modelProfileID)
        generationRecordID = try container.decodeIfPresent(UUID.self, forKey: .generationRecordID)
        approvedAt = try container.decodeIfPresent(Date.self, forKey: .approvedAt)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

public struct ContinuityFact: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var chapterID: UUID
    public var subject: String
    public var predicate: String
    public var value: String
    public var status: FactStatus
    public var conflictWithFactID: UUID?

    public init(id: UUID = UUID(), chapterID: UUID, subject: String, predicate: String, value: String, status: FactStatus = .candidate, conflictWithFactID: UUID? = nil) {
        self.id = id
        self.chapterID = chapterID
        self.subject = subject
        self.predicate = predicate
        self.value = value
        self.status = status
        self.conflictWithFactID = conflictWithFactID
    }
}

public struct ReviewIssue: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var severity: ReviewSeverity
    public var dimension: QualityDimension
    public var title: String
    public var evidence: String
    public var suggestion: String
    public var resolved: Bool

    public init(id: UUID = UUID(), severity: ReviewSeverity, dimension: QualityDimension, title: String, evidence: String = "", suggestion: String = "", resolved: Bool = false) {
        self.id = id
        self.severity = severity
        self.dimension = dimension
        self.title = title
        self.evidence = evidence
        self.suggestion = suggestion
        self.resolved = resolved
    }
}

public struct ReviewReport: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var chapterID: UUID?
    public var chapterVersionID: UUID?
    public var kind: ReviewKind
    public var createdAt: Date
    public var scores: [QualityDimension: Double]
    public var issues: [ReviewIssue]
    public var summary: String
    public var reviewerProfileID: UUID?

    public init(id: UUID = UUID(), chapterID: UUID?, chapterVersionID: UUID? = nil, kind: ReviewKind, createdAt: Date = Date(), scores: [QualityDimension: Double], issues: [ReviewIssue], summary: String, reviewerProfileID: UUID? = nil) {
        self.id = id
        self.chapterID = chapterID
        self.chapterVersionID = chapterVersionID
        self.kind = kind
        self.createdAt = createdAt
        self.scores = scores
        self.issues = issues
        self.summary = summary
        self.reviewerProfileID = reviewerProfileID
    }

    enum CodingKeys: String, CodingKey {
        case id, chapterID, chapterVersionID, kind, createdAt, scores, issues, summary, reviewerProfileID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        chapterID = try container.decodeIfPresent(UUID.self, forKey: .chapterID)
        chapterVersionID = try container.decodeIfPresent(UUID.self, forKey: .chapterVersionID)
        kind = try container.decode(ReviewKind.self, forKey: .kind)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        scores = try container.decode([QualityDimension: Double].self, forKey: .scores)
        issues = try container.decode([ReviewIssue].self, forKey: .issues)
        summary = try container.decode(String.self, forKey: .summary)
        reviewerProfileID = try container.decodeIfPresent(UUID.self, forKey: .reviewerProfileID)
    }
}

public struct GenerationRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var task: String
    public var role: AIRole
    public var modelProfileID: UUID
    public var templateVersion: String
    public var promptHash: String
    public var startedAt: Date
    public var completedAt: Date?
    public var inputCharacters: Int
    public var outputCharacters: Int
    public var status: GenerationStatus
    public var errorMessage: String?
    public var selectedByUser: Bool

    public init(id: UUID = UUID(), task: String, role: AIRole, modelProfileID: UUID, templateVersion: String, promptHash: String, startedAt: Date = Date(), completedAt: Date? = nil, inputCharacters: Int = 0, outputCharacters: Int = 0, status: GenerationStatus = .running, errorMessage: String? = nil, selectedByUser: Bool = false) {
        self.id = id
        self.task = task
        self.role = role
        self.modelProfileID = modelProfileID
        self.templateVersion = templateVersion
        self.promptHash = promptHash
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.inputCharacters = inputCharacters
        self.outputCharacters = outputCharacters
        self.status = status
        self.errorMessage = errorMessage
        self.selectedByUser = selectedByUser
    }
}

public struct PlanningArtifact: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var task: PromptTask
    public var chapterID: UUID?
    public var content: String
    public var modelProfileID: UUID
    public var generationRecordID: UUID
    public var createdAt: Date
    public var selectedAt: Date?

    public init(id: UUID = UUID(), task: PromptTask, chapterID: UUID? = nil, content: String, modelProfileID: UUID, generationRecordID: UUID, createdAt: Date = Date(), selectedAt: Date? = nil) {
        self.id = id
        self.task = task
        self.chapterID = chapterID
        self.content = content
        self.modelProfileID = modelProfileID
        self.generationRecordID = generationRecordID
        self.createdAt = createdAt
        self.selectedAt = selectedAt
    }
}

public struct PlatformProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var notice: String
    public var weights: [QualityDimension: Double]
    public var minimumTotalScore: Double
    public var minimumDimensionScore: Double
    public var updatedAt: Date

    public init(id: String, name: String, notice: String, weights: [QualityDimension: Double], minimumTotalScore: Double = 85, minimumDimensionScore: Double = 75, updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.notice = notice
        self.weights = weights
        self.minimumTotalScore = minimumTotalScore
        self.minimumDimensionScore = minimumDimensionScore
        self.updatedAt = updatedAt
    }
}

public struct AIEndpointProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var endpoint: URL
    public var model: String
    public var authenticationHeader: String
    public var authenticationPrefix: String
    public var keychainReference: String
    public var contextTokenLimit: Int
    public var outputTokenLimit: Int
    public var temperature: Double
    public var timeoutSeconds: Double
    public var streams: Bool

    public init(id: UUID = UUID(), name: String, endpoint: URL, model: String, authenticationHeader: String = "Authorization", authenticationPrefix: String = "Bearer ", keychainReference: String = UUID().uuidString, contextTokenLimit: Int = 32_000, outputTokenLimit: Int = 4_096, temperature: Double = 0.8, timeoutSeconds: Double = 120, streams: Bool = true) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.model = model
        self.authenticationHeader = authenticationHeader
        self.authenticationPrefix = authenticationPrefix
        self.keychainReference = keychainReference
        self.contextTokenLimit = contextTokenLimit
        self.outputTokenLimit = outputTokenLimit
        self.temperature = temperature
        self.timeoutSeconds = timeoutSeconds
        self.streams = streams
    }

    public var isSecure: Bool { endpoint.scheme?.lowercased() == "https" }
}

public struct RoleAssignments: Codable, Hashable, Sendable {
    public var assignments: [AIRole: UUID]

    public init(assignments: [AIRole: UUID] = [:]) {
        self.assignments = assignments
    }
}

public struct StyleProfile: Codable, Hashable, Sendable {
    public var averageSentenceLength: Double
    public var dialogueRatio: Double
    public var paragraphLength: Double
    public var perspective: NarrativePerspective
    public var preferredTerms: [String]
    public var avoidedTerms: [String]
    public var sourceDescription: String

    public init(averageSentenceLength: Double = 0, dialogueRatio: Double = 0, paragraphLength: Double = 0, perspective: NarrativePerspective = .thirdPersonLimited, preferredTerms: [String] = [], avoidedTerms: [String] = [], sourceDescription: String = "用户有权使用的自有样章") {
        self.averageSentenceLength = averageSentenceLength
        self.dialogueRatio = dialogueRatio
        self.paragraphLength = paragraphLength
        self.perspective = perspective
        self.preferredTerms = preferredTerms
        self.avoidedTerms = avoidedTerms
        self.sourceDescription = sourceDescription
    }
}

public struct ProjectWorkspace: Codable, Sendable {
    public var project: NovelProject
    public var bible: StoryBible
    public var characters: [Character]
    public var worldRules: [WorldRule]
    public var timeline: [TimelineEvent]
    public var foreshadowing: [Foreshadowing]
    public var volumes: [VolumeOutline]
    public var chapters: [ChapterCard]
    public var versions: [ChapterVersion]
    public var facts: [ContinuityFact]
    public var reviews: [ReviewReport]
    public var generationRecords: [GenerationRecord]
    public var planningArtifacts: [PlanningArtifact]
    public var styleProfile: StyleProfile?
    public var preferredMode: WorkspaceMode
    public var agentSession: AgentSession
    public var appliedTemplate: WritingTemplateSnapshot?

    public init(
        project: NovelProject,
        bible: StoryBible = StoryBible(),
        characters: [Character] = [],
        worldRules: [WorldRule] = [],
        timeline: [TimelineEvent] = [],
        foreshadowing: [Foreshadowing] = [],
        volumes: [VolumeOutline] = [],
        chapters: [ChapterCard] = [],
        versions: [ChapterVersion] = [],
        facts: [ContinuityFact] = [],
        reviews: [ReviewReport] = [],
        generationRecords: [GenerationRecord] = [],
        planningArtifacts: [PlanningArtifact] = [],
        styleProfile: StyleProfile? = nil,
        preferredMode: WorkspaceMode = .agent,
        agentSession: AgentSession = AgentSession(),
        appliedTemplate: WritingTemplateSnapshot? = nil
    ) {
        self.project = project
        self.bible = bible
        self.characters = characters
        self.worldRules = worldRules
        self.timeline = timeline
        self.foreshadowing = foreshadowing
        self.volumes = volumes
        self.chapters = chapters
        self.versions = versions
        self.facts = facts
        self.reviews = reviews
        self.generationRecords = generationRecords
        self.planningArtifacts = planningArtifacts
        self.styleProfile = styleProfile
        self.preferredMode = preferredMode
        self.agentSession = agentSession
        self.appliedTemplate = appliedTemplate
    }

    public func activeVersion(for chapter: ChapterCard) -> ChapterVersion? {
        guard let activeID = chapter.activeVersionID else { return nil }
        return versions.first { $0.id == activeID }
    }

    enum CodingKeys: String, CodingKey {
        case project, bible, characters, worldRules, timeline, foreshadowing, volumes, chapters, versions
        case facts, reviews, generationRecords, planningArtifacts, styleProfile
        case preferredMode, agentSession, appliedTemplate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        project = try container.decode(NovelProject.self, forKey: .project)
        bible = try container.decodeIfPresent(StoryBible.self, forKey: .bible) ?? StoryBible()
        characters = try container.decodeIfPresent([Character].self, forKey: .characters) ?? []
        worldRules = try container.decodeIfPresent([WorldRule].self, forKey: .worldRules) ?? []
        timeline = try container.decodeIfPresent([TimelineEvent].self, forKey: .timeline) ?? []
        foreshadowing = try container.decodeIfPresent([Foreshadowing].self, forKey: .foreshadowing) ?? []
        volumes = try container.decodeIfPresent([VolumeOutline].self, forKey: .volumes) ?? []
        chapters = try container.decodeIfPresent([ChapterCard].self, forKey: .chapters) ?? []
        versions = try container.decodeIfPresent([ChapterVersion].self, forKey: .versions) ?? []
        facts = try container.decodeIfPresent([ContinuityFact].self, forKey: .facts) ?? []
        reviews = try container.decodeIfPresent([ReviewReport].self, forKey: .reviews) ?? []
        generationRecords = try container.decodeIfPresent([GenerationRecord].self, forKey: .generationRecords) ?? []
        planningArtifacts = try container.decodeIfPresent([PlanningArtifact].self, forKey: .planningArtifacts) ?? []
        styleProfile = try container.decodeIfPresent(StyleProfile.self, forKey: .styleProfile)
        preferredMode = try container.decodeIfPresent(WorkspaceMode.self, forKey: .preferredMode) ?? .agent
        agentSession = try container.decodeIfPresent(AgentSession.self, forKey: .agentSession) ?? AgentSession()
        appliedTemplate = try container.decodeIfPresent(WritingTemplateSnapshot.self, forKey: .appliedTemplate)
    }
}

public struct ProjectArchive: Codable, Sendable {
    public var archiveVersion: Int
    public var exportedAt: Date
    public var workspace: ProjectWorkspace

    public init(archiveVersion: Int = 2, exportedAt: Date = Date(), workspace: ProjectWorkspace) {
        self.archiveVersion = archiveVersion
        self.exportedAt = exportedAt
        self.workspace = workspace
    }
}
