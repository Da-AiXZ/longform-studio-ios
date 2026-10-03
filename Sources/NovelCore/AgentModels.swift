import Foundation

public enum WorkspaceMode: String, Codable, CaseIterable, Hashable, Sendable {
    case agent
    case manual
}

public enum AgentPolicy: String, Codable, CaseIterable, Hashable, Sendable {
    case supervised
    case pass

    public var displayName: String {
        switch self {
        case .supervised: return "监督"
        case .pass: return "Pass"
        }
    }
}

public enum AgentMessageRole: String, Codable, Hashable, Sendable {
    case user
    case assistant
    case tool
    case system
}

public enum AgentMessageKind: String, Codable, Hashable, Sendable {
    case text
    case proposal
    case progress
    case approval
    case report
}

public struct AgentMessage: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var role: AgentMessageRole
    public var kind: AgentMessageKind
    public var content: String
    public var createdAt: Date
    public var relatedRunID: UUID?
    public var relatedApprovalID: UUID?

    public init(
        id: UUID = UUID(),
        role: AgentMessageRole,
        kind: AgentMessageKind = .text,
        content: String,
        createdAt: Date = Date(),
        relatedRunID: UUID? = nil,
        relatedApprovalID: UUID? = nil
    ) {
        self.id = id
        self.role = role
        self.kind = kind
        self.content = content
        self.createdAt = createdAt
        self.relatedRunID = relatedRunID
        self.relatedApprovalID = relatedApprovalID
    }
}

public enum RunScope: Codable, Hashable, Sendable {
    case currentChapter
    case chapterCount(Int)
    case currentVolume

    public var displayName: String {
        switch self {
        case .currentChapter: return "当前章"
        case .chapterCount(let count): return "连续 \(max(1, count)) 章"
        case .currentVolume: return "当前卷"
        }
    }
}

public enum AgentRunStatus: String, Codable, Hashable, Sendable {
    case queued
    case running
    case waitingForApproval
    case paused
    case completed
    case failed
    case cancelled
}

public enum AgentStepStatus: String, Codable, Hashable, Sendable {
    case pending
    case running
    case completed
    case blocked
    case skipped
}

public enum AgentTool: String, Codable, CaseIterable, Hashable, Sendable {
    case readProjectSummary
    case updateProjectMetadata
    case applyPlanningPatch
    case manageVolumeOutline
    case manageChapterCard
    case generateDraft
    case acceptCandidate
    case runReviews
    case rewriteIssues
    case extractFacts
    case evaluateQualityGate
    case approveChapter
    case listTemplates
    case queryManuscriptIndex
    case runHealthCheck

    public var isDestructive: Bool { false }
}

public struct AgentStep: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var tool: AgentTool
    public var title: String
    public var status: AgentStepStatus
    public var attempt: Int
    public var chapterID: UUID?
    public var detail: String
    public var startedAt: Date?
    public var completedAt: Date?

    public init(
        id: UUID = UUID(),
        tool: AgentTool,
        title: String,
        status: AgentStepStatus = .pending,
        attempt: Int = 0,
        chapterID: UUID? = nil,
        detail: String = "",
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.tool = tool
        self.title = title
        self.status = status
        self.attempt = attempt
        self.chapterID = chapterID
        self.detail = detail
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

public struct AgentRun: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var policy: AgentPolicy
    public var scope: RunScope
    public var status: AgentRunStatus
    public var chapterIDs: [UUID]
    public var currentStepIndex: Int
    public var steps: [AgentStep]
    public var maximumModelCalls: Int
    public var modelCallsUsed: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var errorMessage: String?

    public init(
        id: UUID = UUID(),
        policy: AgentPolicy,
        scope: RunScope,
        status: AgentRunStatus = .queued,
        chapterIDs: [UUID],
        currentStepIndex: Int = 0,
        steps: [AgentStep] = [],
        maximumModelCalls: Int,
        modelCallsUsed: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        errorMessage: String? = nil
    ) {
        self.id = id
        self.policy = policy
        self.scope = scope
        self.status = status
        self.chapterIDs = chapterIDs
        self.currentStepIndex = currentStepIndex
        self.steps = steps
        self.maximumModelCalls = maximumModelCalls
        self.modelCallsUsed = modelCallsUsed
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.errorMessage = errorMessage
    }
}

public enum ApprovalKind: String, Codable, Hashable, Sendable {
    case projectPlan
    case storyBible
    case volumeOutline
    case runScope
    case chapterApproval
    case blocker
}

public enum ApprovalStatus: String, Codable, Hashable, Sendable {
    case pending
    case approved
    case revisionRequested
    case dismissed
}

public struct ApprovalRequest: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: ApprovalKind
    public var title: String
    public var summary: String
    public var status: ApprovalStatus
    public var createdAt: Date
    public var resolvedAt: Date?
    public var relatedRunID: UUID?
    public var payload: String?

    public init(
        id: UUID = UUID(),
        kind: ApprovalKind,
        title: String,
        summary: String,
        status: ApprovalStatus = .pending,
        createdAt: Date = Date(),
        resolvedAt: Date? = nil,
        relatedRunID: UUID? = nil,
        payload: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.summary = summary
        self.status = status
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
        self.relatedRunID = relatedRunID
        self.payload = payload
    }
}

public struct AgentSession: Codable, Hashable, Sendable {
    public var policy: AgentPolicy
    public var messages: [AgentMessage]
    public var runs: [AgentRun]
    public var approvals: [ApprovalRequest]
    public var activeRunID: UUID?
    public var updatedAt: Date

    public init(
        policy: AgentPolicy = .supervised,
        messages: [AgentMessage] = [],
        runs: [AgentRun] = [],
        approvals: [ApprovalRequest] = [],
        activeRunID: UUID? = nil,
        updatedAt: Date = Date()
    ) {
        self.policy = policy
        self.messages = messages
        self.runs = runs
        self.approvals = approvals
        self.activeRunID = activeRunID
        self.updatedAt = updatedAt
    }
}

public struct ProjectPlanPatch: Codable, Hashable, Sendable {
    public var baseRevision: Int
    public var title: String? = nil
    public var platform: PublishingPlatform? = nil
    public var genre: String? = nil
    public var sellingPoint: String? = nil
    public var targetWordCount: Int? = nil
    public var protagonistGoal: String? = nil
    public var restrictedContent: [String]? = nil
    public var perspective: NarrativePerspective? = nil
    public var targetChapterWords: Int? = nil
    public var bible: StoryBible? = nil
    public var characters: [Character]? = nil
    public var worldRules: [WorldRule]? = nil
    public var volumes: [VolumeOutline]? = nil
    public var chapters: [ChapterCard]? = nil
    public var selectedTemplateID: UUID? = nil
    public var clearAppliedTemplate: Bool? = nil

    public init(baseRevision: Int) {
        self.baseRevision = baseRevision
    }
}

public enum AgentResponseParserError: LocalizedError {
    case invalidJSON
    case unsupportedTool(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON: return "Agent 返回内容不是合法 JSON。"
        case .unsupportedTool(let value): return "Agent 请求了未授权工具：\(value)。"
        }
    }
}

public struct AgentToolRequest: Codable, Hashable, Sendable {
    public var tool: AgentTool
    public var arguments: [String: String]

    public init(tool: AgentTool, arguments: [String: String] = [:]) {
        self.tool = tool
        self.arguments = arguments
    }

    enum CodingKeys: String, CodingKey { case tool, arguments }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tool = try container.decode(AgentTool.self, forKey: .tool)
        arguments = try container.decodeIfPresent([String: String].self, forKey: .arguments) ?? [:]
    }
}

public struct AgentStoryBibleProposal: Codable, Hashable, Sendable {
    public var premise: String?
    public var themes: [String]?
    public var centralConflict: String?
    public var endingPromise: String?
    public var styleGuide: String?
    public var forbiddenPatterns: [String]?

    public init(premise: String? = nil, themes: [String]? = nil, centralConflict: String? = nil, endingPromise: String? = nil, styleGuide: String? = nil, forbiddenPatterns: [String]? = nil) {
        self.premise = premise
        self.themes = themes
        self.centralConflict = centralConflict
        self.endingPromise = endingPromise
        self.styleGuide = styleGuide
        self.forbiddenPatterns = forbiddenPatterns
    }
}

public struct AgentCharacterProposal: Codable, Hashable, Sendable {
    public var name: String?
    public var role: String?
    public var desire: String?
    public var fear: String?
    public var flaw: String?
    public var arc: String?
    public var voice: String?
    public var currentState: String?

    public init(name: String? = nil, role: String? = nil, desire: String? = nil, fear: String? = nil, flaw: String? = nil, arc: String? = nil, voice: String? = nil, currentState: String? = nil) {
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

public struct AgentWorldRuleProposal: Codable, Hashable, Sendable {
    public var category: String?
    public var title: String?
    public var detail: String?
    public var immutable: Bool?

    public init(category: String? = nil, title: String? = nil, detail: String? = nil, immutable: Bool? = nil) {
        self.category = category
        self.title = title
        self.detail = detail
        self.immutable = immutable
    }
}

public struct AgentVolumeProposal: Codable, Hashable, Sendable {
    public var number: Int?
    public var title: String?
    public var goal: String?
    public var climax: String?
    public var resolution: String?

    public init(number: Int? = nil, title: String? = nil, goal: String? = nil, climax: String? = nil, resolution: String? = nil) {
        self.number = number
        self.title = title
        self.goal = goal
        self.climax = climax
        self.resolution = resolution
    }
}

public struct AgentChapterProposal: Codable, Hashable, Sendable {
    public var number: Int?
    public var title: String?
    public var goal: String?
    public var conflict: String?
    public var turn: String?
    public var hook: String?
    public var summary: String?

    public init(number: Int? = nil, title: String? = nil, goal: String? = nil, conflict: String? = nil, turn: String? = nil, hook: String? = nil, summary: String? = nil) {
        self.number = number
        self.title = title
        self.goal = goal
        self.conflict = conflict
        self.turn = turn
        self.hook = hook
        self.summary = summary
    }
}

public struct AgentPlanProposal: Codable, Hashable, Sendable {
    public var baseRevision: Int
    public var title: String? = nil
    public var platform: PublishingPlatform? = nil
    public var genre: String? = nil
    public var sellingPoint: String? = nil
    public var targetWordCount: Int? = nil
    public var protagonistGoal: String? = nil
    public var restrictedContent: [String]? = nil
    public var perspective: NarrativePerspective? = nil
    public var targetChapterWords: Int? = nil
    public var bible: AgentStoryBibleProposal? = nil
    public var characters: [AgentCharacterProposal]? = nil
    public var worldRules: [AgentWorldRuleProposal]? = nil
    public var volumes: [AgentVolumeProposal]? = nil
    public var chapters: [AgentChapterProposal]? = nil
    public var selectedTemplateID: UUID? = nil
    public var clearAppliedTemplate: Bool? = nil

    public init(baseRevision: Int) {
        self.baseRevision = baseRevision
    }
}

public struct AgentModelResponse: Codable, Hashable, Sendable {
    public var reply: String
    public var proposal: AgentPlanProposal?
    public var toolRequests: [AgentToolRequest]

    public init(reply: String, proposal: AgentPlanProposal? = nil, toolRequests: [AgentToolRequest] = []) {
        self.reply = reply
        self.proposal = proposal
        self.toolRequests = toolRequests
    }

    enum CodingKeys: String, CodingKey { case reply, proposal, toolRequests }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reply = try container.decodeIfPresent(String.self, forKey: .reply) ?? ""
        proposal = try container.decodeIfPresent(AgentPlanProposal.self, forKey: .proposal)
        toolRequests = try container.decodeIfPresent([AgentToolRequest].self, forKey: .toolRequests) ?? []
    }
}

public enum AgentResponseParser {
    public static func decode(_ text: String) throws -> AgentModelResponse {
        let cleaned = PromptCompiler.stripMarkdownCodeFence(text)
        guard let data = cleaned.data(using: .utf8),
              let response = try? JSONDecoder().decode(AgentModelResponse.self, from: data) else {
            throw AgentResponseParserError.invalidJSON
        }
        return response
    }
}
