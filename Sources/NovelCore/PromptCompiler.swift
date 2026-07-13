import Foundation

public struct ChatMessage: Codable, Equatable, Sendable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public enum PromptTask: String, Codable, Hashable, Sendable {
    case creativeOptions
    case storyBible
    case volumeOutline
    case chapterOutline
    case chapterDraft
    case review
    case rewrite
    case extractFacts

    public var displayName: String {
        switch self {
        case .creativeOptions: return "创意方案"
        case .storyBible: return "故事圣经"
        case .volumeOutline: return "卷纲"
        case .chapterOutline: return "章纲"
        case .chapterDraft: return "章节正文"
        case .review: return "审稿"
        case .rewrite: return "改稿"
        case .extractFacts: return "事实提取"
        }
    }
}

public struct PromptRequest: Sendable {
    public var task: PromptTask
    public var project: NovelProject
    public var instruction: String
    public var context: ContextSelection
    public var outputSchema: String?

    public init(task: PromptTask, project: NovelProject, instruction: String, context: ContextSelection, outputSchema: String? = nil) {
        self.task = task
        self.project = project
        self.instruction = instruction
        self.context = context
        self.outputSchema = outputSchema
    }
}

public enum PromptCompiler {
    public static let templateVersion = "1.0.0"

    public static func compile(_ request: PromptRequest) -> [ChatMessage] {
        let roleDescription: String
        switch request.task {
        case .creativeOptions, .storyBible, .volumeOutline, .chapterOutline:
            roleDescription = "你是中文男频长篇小说的资深策划编辑。"
        case .chapterDraft:
            roleDescription = "你是中文男频长篇小说作者，负责严格按已批准规划写出可编辑正文。"
        case .review:
            roleDescription = "你是独立审稿编辑，只依据正文和正式事实审查，不替写作模型辩护。"
        case .rewrite:
            roleDescription = "你是修订编辑，只修复指定问题，并保持未被要求改变的情节事实。"
        case .extractFacts:
            roleDescription = "你是连续性记录员，只提取正文明确成立的事实，不推测。"
        }

        var system = """
        \(roleDescription)
        作品平台：\(request.project.platform.displayName)
        题材：\(request.project.genre)
        叙事视角：\(request.project.perspective.displayName)
        核心卖点：\(request.project.sellingPoint)
        主角长期目标：\(request.project.protagonistGoal)
        限制内容：\(request.project.restrictedContent.isEmpty ? "无额外限制" : request.project.restrictedContent.joined(separator: "、"))

        必须遵守：
        1. 不输出“作为AI”“以下是”等元话语。
        2. 不擅自改写已批准的世界规则、人物状态和时间线。
        3. 信息不足时保守处理，不用巧合或新设定强行解决冲突。
        4. 不照搬参考文本的具体句子，只使用明确给出的抽象风格指标。
        """
        if let schema = request.outputSchema {
            system += "\n5. 只输出一个合法 JSON，不使用 Markdown 代码围栏。结构：\(schema)"
        }

        let contextText = request.context.items.map { item in
            "## \(item.title) [\(item.category.rawValue)]\n\(item.text)"
        }.joined(separator: "\n\n")

        let user = """
        # 已批准上下文
        \(contextText.isEmpty ? "暂无。" : contextText)

        # 本次任务
        \(request.instruction)
        """

        return [ChatMessage(role: "system", content: system), ChatMessage(role: "user", content: user)]
    }

    public static func stripMarkdownCodeFence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        var lines = trimmed.components(separatedBy: .newlines)
        if !lines.isEmpty { lines.removeFirst() }
        if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "```" { lines.removeLast() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
