import Foundation
import NovelCore

@MainActor
final class WorkflowToolExecutor {
    private let apiKeyOverride: String?

    init(apiKeyOverride: String? = nil) {
        self.apiKeyOverride = apiKeyOverride
    }

    struct PlanningResult {
        var text: String
        var artifactID: UUID
    }

    struct DraftResult {
        var version: ChapterVersion
        var text: String
        var finishReason: String?
    }

    func completePlanning(
        task: PromptTask,
        instruction: String,
        chapter: ChapterCard? = nil,
        session: ProjectSession
    ) async throws -> PlanningResult {
        let profile = try profile(for: .planner, session: session)
        let key = try apiKey(for: profile, session: session)
        let context = if let chapter {
            try await context(for: chapter, session: session, profile: profile)
        } else {
            generalContext(session: session, profile: profile)
        }
        let messages = PromptCompiler.compile(PromptRequest(task: task, project: session.workspace.project, instruction: instruction, context: context))
        let completion = try await session.aiClient.complete(profile: profile, apiKey: key, messages: messages)
        let record = completedRecord(task: task.rawValue, role: .planner, profile: profile, messages: messages, output: completion.content)
        session.addGenerationRecord(record)
        let artifact = PlanningArtifact(task: task, chapterID: chapter?.id, content: completion.content, modelProfileID: profile.id, generationRecordID: record.id)
        session.addPlanningArtifact(artifact)
        return PlanningResult(text: completion.content, artifactID: artifact.id)
    }

    func generateDraft(
        session: ProjectSession,
        chapter: ChapterCard,
        onStream: @escaping @MainActor (String, String?) -> Void = { _, _ in }
    ) async throws -> DraftResult {
        let profile = try profile(for: .writer, session: session)
        let key = try apiKey(for: profile, session: session)
        let context = try await context(for: chapter, session: session, profile: profile)
        let templateInstruction = session.workspace.appliedTemplate.map { templatePrompt($0.template) } ?? ""
        let instruction = """
        写出第\(chapter.number)章《\(chapter.title)》完整正文，目标约 \(session.workspace.project.targetChapterWords) 个汉字。
        章目标：\(chapter.goal)
        核心冲突：\(chapter.conflict)
        关键转折：\(chapter.turn)
        结尾钩子：\(chapter.hook)
        \(templateInstruction)
        正文必须有清晰场景推进和因果链，只输出小说正文。
        """
        let messages = PromptCompiler.compile(PromptRequest(task: .chapterDraft, project: session.workspace.project, instruction: instruction, context: context))
        let recordID = UUID()
        var record = GenerationRecord(
            id: recordID,
            task: PromptTask.chapterDraft.rawValue,
            role: .writer,
            modelProfileID: profile.id,
            templateVersion: PromptCompiler.templateVersion,
            promptHash: Self.stableHash(messages.map(\.content).joined()),
            inputCharacters: messages.map(\.content.count).reduce(0, +)
        )
        var text = ""
        var finishReason: String?
        do {
            if profile.streams {
                for try await value in session.aiClient.stream(profile: profile, apiKey: key, messages: messages) {
                    try Task.checkCancellation()
                    switch value {
                    case .text(let fragment): text += fragment
                    case .finished(let reason): finishReason = reason
                    }
                    onStream(text, finishReason)
                }
            } else {
                let completion = try await session.aiClient.complete(profile: profile, apiKey: key, messages: messages)
                text = completion.content
                finishReason = completion.finishReason
                onStream(text, finishReason)
            }

            if finishReason == "length", !text.isEmpty {
                let tail = String(text.suffix(1_000))
                let continuationMessages = messages + [
                    ChatMessage(role: "assistant", content: tail),
                    ChatMessage(role: "user", content: "从上文截断处继续写完本章。先重复末尾少量文字用于衔接，只输出续写正文，不总结。")
                ]
                let continuation = try await session.aiClient.complete(profile: profile, apiKey: key, messages: continuationMessages)
                text = TextContinuationMerger.merge(existing: text, continuation: continuation.content)
                finishReason = continuation.finishReason
                onStream(text, finishReason)
            }

            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIClientError.emptyResponse }
            record.status = .completed
            record.completedAt = Date()
            record.outputCharacters = text.count
            session.addGenerationRecord(record)
            let version = session.addCandidateVersion(chapterID: chapter.id, body: text, source: .generated, profileID: profile.id, generationRecordID: recordID, note: "AI 生成候选，尚未接受")
            return DraftResult(version: version, text: text, finishReason: finishReason)
        } catch {
            record.status = error is CancellationError ? .cancelled : .failed
            record.completedAt = Date()
            record.outputCharacters = text.count
            record.errorMessage = error.localizedDescription
            session.addGenerationRecord(record)
            if !text.isEmpty {
                _ = session.addCandidateVersion(chapterID: chapter.id, body: text, source: .generated, profileID: profile.id, generationRecordID: recordID, note: "请求中断后保留的部分候选")
            }
            throw error
        }
    }

    func prepareChapterCard(session: ProjectSession, chapter: ChapterCard) async throws -> ChapterCard {
        let profile = try profile(for: .planner, session: session)
        let key = try apiKey(for: profile, session: session)
        let context = try await context(for: chapter, session: session, profile: profile)
        let instruction = """
        为第\(chapter.number)章生成一个可直接执行的章卡。必须承接已批准设定与上一章，包含标题、章节目标、核心冲突、关键转折、结尾钩子和供后续检索的事实摘要。不要解释。
        """
        let schema = "{\"title\":\"\",\"goal\":\"\",\"conflict\":\"\",\"turn\":\"\",\"hook\":\"\",\"summary\":\"\"}"
        let messages = PromptCompiler.compile(PromptRequest(task: .chapterOutline, project: session.workspace.project, instruction: instruction, context: context, outputSchema: schema))
        let output = try await completeJSON(profile: profile, key: key, messages: messages, session: session)
        let payload = try JSONDecoder().decode(ChapterCardPayload.self, from: Data(PromptCompiler.stripMarkdownCodeFence(output).utf8))
        guard !payload.goal.isEmpty, !payload.conflict.isEmpty, !payload.hook.isEmpty else { throw WorkflowToolError.incompleteChapterCard }
        session.updateChapterCard(id: chapter.id) { value in
            if !payload.title.isEmpty { value.title = payload.title }
            value.goal = payload.goal
            value.conflict = payload.conflict
            value.turn = payload.turn
            value.hook = payload.hook
            value.summary = payload.summary
        }
        return session.workspace.chapters.first(where: { $0.id == chapter.id }) ?? chapter
    }

    func runReviews(session: ProjectSession, chapter: ChapterCard) async throws -> [ReviewReport] {
        try await runReviews(session: session, chapter: chapter, kinds: [.plot, .continuity, .prose, .platform])
    }

    func runReviews(session: ProjectSession, chapter: ChapterCard, kinds: [ReviewKind]) async throws -> [ReviewReport] {
        let body = try await session.body(for: chapter)
        guard !body.isEmpty else { throw AIClientError.emptyResponse }
        var reports: [ReviewReport] = []
        for kind in kinds {
            try Task.checkCancellation()
            let report = try await review(kind: kind, body: body, chapter: chapter, session: session)
            session.addReview(report)
            reports.append(report)
        }
        return reports
    }

    func rewrite(
        session: ProjectSession,
        chapter: ChapterCard,
        issueIDs: Set<UUID>
    ) async throws -> ChapterVersion {
        let current = try await session.body(for: chapter)
        guard !current.isEmpty else { throw AIClientError.emptyResponse }
        let selected = session.unresolvedIssues(for: chapter).filter { issueIDs.contains($0.id) }
        guard !selected.isEmpty else { throw WorkflowToolError.noIssuesSelected }
        let profile = try profile(for: .rewriter, session: session)
        let key = try apiKey(for: profile, session: session)
        let issueText = selected.map { "- [\($0.severity.rawValue)] \($0.title)：\($0.evidence)；建议：\($0.suggestion)" }.joined(separator: "\n")
        let context = try await context(for: chapter, session: session, profile: profile)
        let instruction = """
        只修复以下已选问题，保持其他情节事实、人物状态、视角、章末钩子不变：
        \(issueText)

        原正文：
        \(current)

        输出修订后的完整章节正文，不解释修改过程。
        """
        let messages = PromptCompiler.compile(PromptRequest(task: .rewrite, project: session.workspace.project, instruction: instruction, context: context))
        let result = try await session.aiClient.complete(profile: profile, apiKey: key, messages: messages)
        let record = completedRecord(task: PromptTask.rewrite.rawValue, role: .rewriter, profile: profile, messages: messages, output: result.content)
        session.addGenerationRecord(record)
        return session.addCandidateVersion(chapterID: chapter.id, body: result.content, source: .rewritten, profileID: profile.id, generationRecordID: record.id, note: "针对 \(selected.count) 个问题的修订候选")
    }

    func rewriteSelection(
        session: ProjectSession,
        chapter: ChapterCard,
        range: NSRange,
        instruction: String
    ) async throws -> ChapterVersion {
        let current = try await session.body(for: chapter)
        guard let swiftRange = Range(range, in: current), !swiftRange.isEmpty else { throw WorkflowToolError.noSelection }
        let selection = String(current[swiftRange])
        let profile = try profile(for: .rewriter, session: session)
        let key = try apiKey(for: profile, session: session)
        let context = try await context(for: chapter, session: session, profile: profile)
        let taskInstruction = """
        按用户要求改写选中片段，只输出可直接替换原片段的新文字。保持与上下文一致，不新增未批准设定。
        用户要求：\(instruction)
        选中片段：
        \(selection)
        """
        let messages = PromptCompiler.compile(PromptRequest(task: .rewrite, project: session.workspace.project, instruction: taskInstruction, context: context))
        let result = try await session.aiClient.complete(profile: profile, apiKey: key, messages: messages)
        var revised = current
        revised.replaceSubrange(swiftRange, with: result.content.trimmingCharacters(in: .whitespacesAndNewlines))
        let record = completedRecord(task: "selectionRewrite", role: .rewriter, profile: profile, messages: messages, output: result.content)
        session.addGenerationRecord(record)
        return session.addCandidateVersion(chapterID: chapter.id, body: revised, source: .rewritten, profileID: profile.id, generationRecordID: record.id, note: "选段改写：\(instruction)")
    }

    func extractFacts(session: ProjectSession, chapter: ChapterCard) async throws -> [ContinuityFact] {
        let body = try await session.body(for: chapter)
        guard !body.isEmpty else { throw AIClientError.emptyResponse }
        let profile = try profile(for: .memoryExtractor, session: session)
        let key = try apiKey(for: profile, session: session)
        let accepted = session.workspace.facts.filter { $0.status == .accepted }.map { "\($0.subject)|\($0.predicate)|\($0.value)" }.joined(separator: "\n")
        let instruction = """
        从本章正文提取会影响后续连续性的明确事实。只记录人物状态、物品归属、地点、时间、关系、能力和伏笔变化。对照正式事实标记可能冲突，但不要自行裁决。
        正式事实：
        \(accepted.isEmpty ? "暂无" : accepted)
        本章正文：
        \(body)
        """
        let schema = "{\"facts\":[{\"subject\":\"\",\"predicate\":\"\",\"value\":\"\",\"conflict_with_fact_id\":null}]}"
        let context = try await context(for: chapter, session: session, profile: profile)
        let messages = PromptCompiler.compile(PromptRequest(task: .extractFacts, project: session.workspace.project, instruction: instruction, context: context, outputSchema: schema))
        let completion = try await completeJSON(profile: profile, key: key, messages: messages, session: session)
        let payload = try JSONDecoder().decode(FactsPayload.self, from: Data(PromptCompiler.stripMarkdownCodeFence(completion).utf8))
        let facts = payload.facts.compactMap { item -> ContinuityFact? in
            guard !item.subject.isEmpty, !item.predicate.isEmpty, !item.value.isEmpty else { return nil }
            return ContinuityFact(chapterID: chapter.id, subject: item.subject, predicate: item.predicate, value: item.value, status: .candidate, conflictWithFactID: item.conflictWithFactID)
        }
        session.addCandidateFacts(facts)
        return facts
    }

    func runRegressionReview(session: ProjectSession) async throws -> ReviewReport {
        let approved = session.sortedChapters.filter { $0.status == .approved }
        guard !approved.isEmpty else { throw WorkflowToolError.noApprovedChapters }
        let chapters = Array(approved.suffix(10))
        let profile = try profile(for: .reviewer, session: session)
        let key = try apiKey(for: profile, session: session)
        let platform = session.settings.platformProfile(for: session.workspace.project.platform)
        let dimensions = platform.weights.keys.map(\.rawValue).sorted().joined(separator: ", ")
        var parts: [String] = []
        for chapter in chapters {
            let body = try await session.body(for: chapter)
            parts.append("# 第\(chapter.number)章 \(chapter.title)\n摘要：\(chapter.summary)\n正文：\(body)")
        }
        let instruction = """
        对以下最近 \(chapters.count) 个已批准章节做跨章回归审稿。重点检查人物状态漂移、力量体系冲突、重复剧情、长期目标停滞、遗忘伏笔和时间线错误，并按这些维度评分：\(dimensions)。
        \(parts.joined(separator: "\n\n"))
        """
        let schema = reviewSchema
        let messages = PromptCompiler.compile(PromptRequest(task: .review, project: session.workspace.project, instruction: instruction, context: generalContext(session: session, profile: profile), outputSchema: schema))
        let output = try await completeJSON(profile: profile, key: key, messages: messages, session: session)
        let payload = try JSONDecoder().decode(ReviewPayload.self, from: Data(PromptCompiler.stripMarkdownCodeFence(output).utf8))
        let report = makeReport(payload: payload, chapterID: nil, chapterVersionID: nil, kind: .regression, profileID: profile.id)
        session.addReview(report)
        return report
    }

    func completeAgent(messages: [ChatMessage], session: ProjectSession) async throws -> String {
        let profile = try profile(for: .planner, session: session)
        let key = try apiKey(for: profile, session: session)
        return try await session.aiClient.complete(profile: profile, apiKey: key, messages: messages).content
    }

    func synthesizeTemplate(index: ManuscriptIndex, localTemplate: WritingTemplate, session: ProjectSession) async throws -> WritingTemplate {
        try await synthesizeTemplate(index: index, localTemplate: localTemplate, settings: session.settings, aiClient: session.aiClient)
    }

    func synthesizeTemplate(
        index: ManuscriptIndex,
        localTemplate: WritingTemplate,
        settings: SettingsStore,
        aiClient: AIChatClient = OpenAICompatibleClient()
    ) async throws -> WritingTemplate {
        guard let profile = settings.profile(for: .planner) else { throw WorkflowToolError.missingProfile(AIRole.planner.displayName) }
        guard profile.isSecure else { throw AIClientError.insecureEndpoint }
        guard let key = try settings.keychain.value(for: profile.keychainReference), !key.isEmpty else { throw AIClientError.missingKey }
        let evidence = index.representativeEvidence.map { "第\($0.chapterNumber)章 \($0.location)：\($0.paraphrase)" }.joined(separator: "\n")
        let sampledMetrics: [ManuscriptChapterMetric]
        if index.chapterMetrics.count <= 500 {
            sampledMetrics = index.chapterMetrics
        } else {
            let stride = Double(index.chapterMetrics.count - 1) / 499.0
            sampledMetrics = (0..<500).map { offset in
                index.chapterMetrics[min(index.chapterMetrics.count - 1, Int((Double(offset) * stride).rounded()))]
            }
        }
        let metrics = sampledMetrics.map { "第\($0.number)章|\($0.characterCount)字|\($0.paragraphCount)段|开篇:\($0.openingPattern)|章末:\($0.endingPattern)" }.joined(separator: "\n")
        let concepts = index.nodes.prefix(80).map { "\($0.label):\($0.frequency)" }.joined(separator: "、")
        let labels = Dictionary(uniqueKeysWithValues: index.nodes.map { ($0.id, $0.label) })
        let relations = index.edges.sorted { $0.weight > $1.weight }.prefix(240).map { edge in
            "\(labels[edge.source] ?? edge.source) -[\(edge.relation):\(edge.weight)]-> \(labels[edge.target] ?? edge.target)"
        }.joined(separator: "\n")
        let schema = "{\"summary\":\"\",\"structure_strategies\":[\"\"],\"pacing_strategies\":[\"\"],\"payoff_strategies\":[\"\"],\"foreshadowing_strategies\":[\"\"],\"hook_strategies\":[\"\"],\"chapter_constraints\":[\"\"],\"recommended_practices\":[\"\"],\"avoided_practices\":[\"\"],\"suitable_genres\":[\"\"],\"confidence\":0.0}"
        let system = """
        你是长篇小说结构分析工具。只根据统计、关系节点和释义证据提炼抽象写作策略，不模仿具体句子、专名或独特情节。只输出合法 JSON，结构：\(schema)
        """
        let user = """
        来源：\(index.sourceName)，全文约 \(index.analyzedCharacters) 字，共 \(index.chapterMetrics.count) 章。
        高频抽象节点：\(concepts)
        章节与概念关系：
        \(relations)
        章节统计：
        \(metrics)
        结构证据：
        \(evidence)
        """
        let messages = [ChatMessage(role: "system", content: system), ChatMessage(role: "user", content: user)]
        guard TokenEstimator.estimate(messages.map(\.content).joined()) <= min(80_000, profile.contextTokenLimit - profile.outputTokenLimit) else {
            throw WorkflowToolError.analysisBudgetExceeded
        }
        let output = try await completeJSON(profile: profile, key: key, messages: messages, aiClient: aiClient)
        let payload = try JSONDecoder().decode(TemplateSynthesisPayload.self, from: Data(PromptCompiler.stripMarkdownCodeFence(output).utf8))
        var result = localTemplate
        result.summary = payload.summary
        result.structureStrategies = payload.structureStrategies
        result.pacingStrategies = payload.pacingStrategies
        result.payoffStrategies = payload.payoffStrategies
        result.foreshadowingStrategies = payload.foreshadowingStrategies
        result.hookStrategies = payload.hookStrategies
        result.chapterConstraints = payload.chapterConstraints
        result.recommendedPractices = payload.recommendedPractices
        result.avoidedPractices = payload.avoidedPractices
        result.suitableGenres = payload.suitableGenres
        result.confidence = min(1, max(0, payload.confidence))
        return result
    }

    private func review(kind: ReviewKind, body: String, chapter: ChapterCard, session: ProjectSession) async throws -> ReviewReport {
        let profile = try profile(for: .reviewer, session: session)
        let key = try apiKey(for: profile, session: session)
        let platform = session.settings.platformProfile(for: session.workspace.project.platform)
        let dimensions = platform.weights.keys.map(\.rawValue).sorted().joined(separator: ", ")
        let instruction = """
        以“\(kind.displayName)”身份审查第\(chapter.number)章。逐项给出 0-100 分；必须引用正文证据，不因文笔流畅而忽略事实冲突。
        必须评分的维度：\(dimensions)
        正文：
        \(body)
        """
        let context = try await context(for: chapter, session: session, profile: profile, includePreviousChapter: false)
        let messages = PromptCompiler.compile(PromptRequest(task: .review, project: session.workspace.project, instruction: instruction, context: context, outputSchema: reviewSchema))
        let output = try await completeJSON(profile: profile, key: key, messages: messages, session: session)
        let payload = try JSONDecoder().decode(ReviewPayload.self, from: Data(PromptCompiler.stripMarkdownCodeFence(output).utf8))
        return makeReport(payload: payload, chapterID: chapter.id, chapterVersionID: chapter.activeVersionID, kind: kind, profileID: profile.id)
    }

    private func makeReport(payload: ReviewPayload, chapterID: UUID?, chapterVersionID: UUID?, kind: ReviewKind, profileID: UUID) -> ReviewReport {
        let scores = Dictionary(uniqueKeysWithValues: payload.scores.compactMap { key, value in QualityDimension(rawValue: key).map { ($0, value) } })
        let issues = payload.issues.compactMap { item -> ReviewIssue? in
            guard let severity = ReviewSeverity(rawValue: item.severity), let dimension = QualityDimension(rawValue: item.dimension) else { return nil }
            return ReviewIssue(severity: severity, dimension: dimension, title: item.title, evidence: item.evidence, suggestion: item.suggestion)
        }
        return ReviewReport(chapterID: chapterID, chapterVersionID: chapterVersionID, kind: kind, scores: scores, issues: issues, summary: payload.summary, reviewerProfileID: profileID)
    }

    private func completeJSON(profile: AIEndpointProfile, key: String, messages: [ChatMessage], session: ProjectSession) async throws -> String {
        try await completeJSON(profile: profile, key: key, messages: messages, aiClient: session.aiClient)
    }

    private func completeJSON(profile: AIEndpointProfile, key: String, messages: [ChatMessage], aiClient: AIChatClient) async throws -> String {
        let first = try await aiClient.complete(profile: profile, apiKey: key, messages: messages)
        let cleaned = PromptCompiler.stripMarkdownCodeFence(first.content)
        if (try? JSONSerialization.jsonObject(with: Data(cleaned.utf8))) != nil { return cleaned }
        let repair = messages + [
            ChatMessage(role: "assistant", content: first.content),
            ChatMessage(role: "user", content: "上一个结果不是合法 JSON。只修复格式并完整输出一个合法 JSON；不得添加解释或 Markdown 围栏。")
        ]
        let repaired = try await aiClient.complete(profile: profile, apiKey: key, messages: repair).content
        let repairedCleaned = PromptCompiler.stripMarkdownCodeFence(repaired)
        guard (try? JSONSerialization.jsonObject(with: Data(repairedCleaned.utf8))) != nil else { throw AgentResponseParserError.invalidJSON }
        return repairedCleaned
    }

    private func profile(for role: AIRole, session: ProjectSession) throws -> AIEndpointProfile {
        guard let profile = session.settings.profile(for: role) else { throw WorkflowToolError.missingProfile(role.displayName) }
        guard profile.isSecure else { throw AIClientError.insecureEndpoint }
        return profile
    }

    private func apiKey(for profile: AIEndpointProfile, session: ProjectSession) throws -> String {
        if let apiKeyOverride, !apiKeyOverride.isEmpty { return apiKeyOverride }
        guard let key = try session.settings.keychain.value(for: profile.keychainReference), !key.isEmpty else { throw AIClientError.missingKey }
        return key
    }

    private func generalContext(session: ProjectSession, profile: AIEndpointProfile) -> ContextSelection {
        ContextBuilder.select(from: baseContextItems(session: session), contextLimit: profile.contextTokenLimit, outputReserve: profile.outputTokenLimit)
    }

    private func context(for chapter: ChapterCard, session: ProjectSession, profile: AIEndpointProfile, includePreviousChapter: Bool = true) async throws -> ContextSelection {
        var items = baseContextItems(session: session)
        let chapterText = "目标：\(chapter.goal)\n冲突：\(chapter.conflict)\n转折：\(chapter.turn)\n钩子：\(chapter.hook)"
        items.append(ContextItem(id: "chapter-card", category: .outline, title: "本章章卡", text: chapterText, priority: 100, required: true))
        for character in session.workspace.characters where chapter.linkedEntityIDs.contains(character.id) {
            let text = "角色：\(character.name)\n定位：\(character.role)\n欲望：\(character.desire)\n缺陷：\(character.flaw)\n当前状态：\(character.currentState)\n口吻：\(character.voice)"
            items.append(ContextItem(id: character.id.uuidString, category: .entity, title: "关联人物：\(character.name)", text: text, priority: 90, required: true))
        }
        let facts = session.workspace.facts.filter { $0.status == .accepted }.map { "\($0.subject)｜\($0.predicate)｜\($0.value)" }.joined(separator: "\n")
        if !facts.isEmpty { items.append(ContextItem(id: "facts", category: .continuity, title: "正式连续性事实", text: facts, priority: 95, required: true)) }
        let sorted = session.sortedChapters
        if let currentIndex = sorted.firstIndex(where: { $0.id == chapter.id }) {
            if includePreviousChapter, currentIndex > 0 {
                let body = try await session.body(for: sorted[currentIndex - 1])
                items.append(ContextItem(id: "previous-chapter", category: .previousChapter, title: "上一章正文", text: body, priority: 85, required: true))
            }
            if currentIndex > 1 {
                for previous in sorted.prefix(currentIndex - 1) where !previous.summary.isEmpty {
                    items.append(ContextItem(id: "summary-\(previous.id)", category: .earlierSummary, title: "第\(previous.number)章摘要", text: previous.summary, priority: 30, relevance: ContextBuilder.relevance(of: previous.summary, to: chapterText)))
                }
            }
            items.append(contentsOf: try await session.searchHistoricalPassages(before: chapter, query: chapterText))
        }
        return ContextBuilder.select(from: items, contextLimit: profile.contextTokenLimit, outputReserve: profile.outputTokenLimit)
    }

    private func baseContextItems(session: ProjectSession) -> [ContextItem] {
        let bible = session.workspace.bible
        var items = [ContextItem(id: "bible", category: .storyBible, title: "已批准故事圣经", text: "前提：\(bible.premise)\n主题：\(bible.themes.joined(separator: "、"))\n中央冲突：\(bible.centralConflict)\n终局承诺：\(bible.endingPromise)\n文风：\(bible.styleGuide)\n禁忌：\(bible.forbiddenPatterns.joined(separator: "、"))", priority: 100, required: true)]
        let rules = session.workspace.worldRules.map { "[\($0.category)] \($0.title)：\($0.detail)" }.joined(separator: "\n")
        if !rules.isEmpty { items.append(ContextItem(id: "world-rules", category: .storyBible, title: "世界硬规则", text: rules, priority: 95, required: true)) }
        if let style = session.workspace.styleProfile {
            items.append(ContextItem(id: "style", category: .instruction, title: "抽象文风", text: "平均句长 \(Int(style.averageSentenceLength))；对话比例 \(Int(style.dialogueRatio * 100))%；平均段长 \(Int(style.paragraphLength))；视角 \(style.perspective.displayName)。", priority: 70))
        }
        if let template = session.workspace.appliedTemplate?.template {
            items.append(ContextItem(id: "writing-template", category: .instruction, title: "已选写作模板", text: templatePrompt(template), priority: 88, required: true))
        }
        return items
    }

    private func templatePrompt(_ template: WritingTemplate) -> String {
        """
        使用已确认的抽象写作模板“\(template.name)”：
        文风统计：平均句长 \(Int(template.style.averageSentenceLength)) 字；对话比例 \(Int(template.style.dialogueRatio * 100))%；平均段长 \(Int(template.style.paragraphLength)) 字；视角 \(template.style.perspective.displayName)。
        结构：\(template.structureStrategies.joined(separator: "；"))
        节奏：\(template.pacingStrategies.joined(separator: "；"))
        爽点：\(template.payoffStrategies.joined(separator: "；"))
        伏笔：\(template.foreshadowingStrategies.joined(separator: "；"))
        钩子：\(template.hookStrategies.joined(separator: "；"))
        禁止：\(template.avoidedPractices.joined(separator: "；"))
        只学习抽象策略，不复用来源作品的具体句子、专名或情节。
        """
    }

    private func completedRecord(task: String, role: AIRole, profile: AIEndpointProfile, messages: [ChatMessage], output: String) -> GenerationRecord {
        GenerationRecord(task: task, role: role, modelProfileID: profile.id, templateVersion: PromptCompiler.templateVersion, promptHash: Self.stableHash(messages.map(\.content).joined()), completedAt: Date(), inputCharacters: messages.map(\.content.count).reduce(0, +), outputCharacters: output.count, status: .completed)
    }

    private var reviewSchema: String {
        "{\"scores\":{\"dimension_key\":0},\"issues\":[{\"severity\":\"info|low|medium|high|critical\",\"dimension\":\"dimension_key\",\"title\":\"\",\"evidence\":\"\",\"suggestion\":\"\"}],\"summary\":\"\"}"
    }

    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 { hash ^= UInt64(byte); hash &*= 1_099_511_628_211 }
        return String(hash, radix: 16)
    }
}

enum WorkflowToolError: LocalizedError {
    case missingProfile(String)
    case noIssuesSelected
    case noApprovedChapters
    case noSelection
    case analysisBudgetExceeded
    case incompleteChapterCard

    var errorDescription: String? {
        switch self {
        case .missingProfile(let role): return "请先在设置中为“\(role)”配置模型。"
        case .noIssuesSelected: return "请至少选择一个待修复问题。"
        case .noApprovedChapters: return "至少需要一个已批准章节才能运行跨章回归审稿。"
        case .noSelection: return "请先在正文中选择需要改写的文字。"
        case .analysisBudgetExceeded: return "分析摘要超过 80,000 Token 上限，请减少证据范围后重试。"
        case .incompleteChapterCard: return "模型返回的章卡缺少目标、冲突或结尾钩子。"
        }
    }
}

private struct ChapterCardPayload: Decodable {
    var title: String
    var goal: String
    var conflict: String
    var turn: String
    var hook: String
    var summary: String
}

private struct ReviewPayload: Decodable {
    struct Issue: Decodable {
        var severity: String
        var dimension: String
        var title: String
        var evidence: String
        var suggestion: String
    }
    var scores: [String: Double]
    var issues: [Issue]
    var summary: String
}

private struct FactsPayload: Decodable {
    struct Fact: Decodable {
        var subject: String
        var predicate: String
        var value: String
        var conflictWithFactID: UUID?

        enum CodingKeys: String, CodingKey {
            case subject, predicate, value
            case conflictWithFactID = "conflict_with_fact_id"
        }
    }
    var facts: [Fact]
}

private struct TemplateSynthesisPayload: Decodable {
    var summary: String
    var structureStrategies: [String]
    var pacingStrategies: [String]
    var payoffStrategies: [String]
    var foreshadowingStrategies: [String]
    var hookStrategies: [String]
    var chapterConstraints: [String]
    var recommendedPractices: [String]
    var avoidedPractices: [String]
    var suitableGenres: [String]
    var confidence: Double

    enum CodingKeys: String, CodingKey {
        case summary, confidence
        case structureStrategies = "structure_strategies"
        case pacingStrategies = "pacing_strategies"
        case payoffStrategies = "payoff_strategies"
        case foreshadowingStrategies = "foreshadowing_strategies"
        case hookStrategies = "hook_strategies"
        case chapterConstraints = "chapter_constraints"
        case recommendedPractices = "recommended_practices"
        case avoidedPractices = "avoided_practices"
        case suitableGenres = "suitable_genres"
    }
}
