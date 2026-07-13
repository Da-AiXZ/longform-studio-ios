import Foundation
import Combine
import NovelCore

@MainActor
final class AIWorkflowController: ObservableObject {
    enum State: Equatable {
        case idle
        case running(String)
        case completed(String)
        case failed(String)
        case cancelled
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var streamedText = ""
    @Published private(set) var finishReason: String?
    @Published var planningResult = ""
    @Published var latestPlanningArtifactID: UUID?
    private var task: Task<Void, Never>?

    func cancel() {
        guard task != nil else { return }
        task?.cancel()
        task = nil
        state = .cancelled
    }

    func generateCreativeOptions(session: ProjectSession) {
        run(label: "生成创意方案") { [weak self, weak session] in
            guard let self, let session else { return }
            let instruction = """
            基于作品信息提出三个明显不同、可支撑长篇连载的创意方案。每个方案包含：一句话卖点、主角起点、核心机制、前30章主线、长期升级空间、主要风险。方案之间不能只换名字。
            """
            let output = try await self.completePlanning(task: .creativeOptions, instruction: instruction, session: session)
            self.planningResult = output
            self.state = .completed("已生成 3 个创意方案，请人工选择并整理进故事圣经。")
        }
    }

    func generateStoryBibleCandidate(session: ProjectSession) {
        run(label: "生成故事圣经候选") { [weak self, weak session] in
            guard let self, let session else { return }
            let instruction = """
            生成一份可供人工确认的故事圣经，包含：核心前提、主题、中央冲突、终局承诺、主角弧线、力量体系硬规则、长线悬念、文风边界和禁止使用的廉价解法。不要把候选内容当成已经批准的正式事实。
            """
            let output = try await self.completePlanning(task: .storyBible, instruction: instruction, session: session)
            self.planningResult = output
            self.state = .completed("故事圣经候选已生成，确认后再写入规划。")
        }
    }

    func generateVolumeOutline(session: ProjectSession) {
        run(label: "生成卷纲候选") { [weak self, weak session] in
            guard let self, let session else { return }
            let instruction = """
            基于已批准故事圣经生成下一卷卷纲。说明本卷目标、主要对手、阶段性升级、每个转折的因果链、高潮、付费/追读节点、卷末兑现与下一卷悬念。只输出候选，不擅自新增正式世界规则。
            """
            let output = try await self.completePlanning(task: .volumeOutline, instruction: instruction, session: session)
            self.planningResult = output
            self.state = .completed("卷纲候选已生成，请人工确认。")
        }
    }

    func generateChapterOutlineOptions(session: ProjectSession, chapter: ChapterCard) {
        run(label: "生成章纲方案") { [weak self, weak session] in
            guard let self, let session else { return }
            let instruction = """
            为第\(chapter.number)章《\(chapter.title)》提出两个结构明显不同的章纲方案。每个方案包含：章节目标、冲突升级、三个场景、信息释放、转折、兑现和结尾钩子，并说明与前章及长线目标的连接。
            """
            let output = try await self.completePlanning(task: .chapterOutline, instruction: instruction, chapter: chapter, session: session)
            self.planningResult = output
            self.state = .completed("已生成两个章纲方案，请选择后填写章卡。")
        }
    }

    func generateDraft(session: ProjectSession, chapter: ChapterCard) {
        run(label: "生成章节候选") { [weak self, weak session] in
            guard let self, let session else { return }
            let profile = try self.profile(for: .writer, session: session)
            let apiKey = try self.key(for: profile, session: session)
            let context = try await self.context(for: chapter, session: session, profile: profile)
            let instruction = """
            写出第\(chapter.number)章《\(chapter.title)》完整正文，目标约 \(session.workspace.project.targetChapterWords) 个汉字。
            章目标：\(chapter.goal)
            核心冲突：\(chapter.conflict)
            关键转折：\(chapter.turn)
            结尾钩子：\(chapter.hook)
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
            self.streamedText = ""
            self.finishReason = nil
            do {
                if profile.streams {
                    for try await value in session.aiClient.stream(profile: profile, apiKey: apiKey, messages: messages) {
                        try Task.checkCancellation()
                        switch value {
                        case .text(let text): self.streamedText += text
                        case .finished(let reason): self.finishReason = reason
                        }
                    }
                } else {
                    let completion = try await session.aiClient.complete(profile: profile, apiKey: apiKey, messages: messages)
                    self.streamedText = completion.content
                    self.finishReason = completion.finishReason
                }

                if self.finishReason == "length", !self.streamedText.isEmpty {
                    self.state = .running("正文达到输出上限，补写结尾")
                    let tail = String(self.streamedText.suffix(1_000))
                    let continuationMessages = messages + [
                        ChatMessage(role: "assistant", content: tail),
                        ChatMessage(role: "user", content: "从上文截断处继续写完本章。先重复末尾少量文字用于衔接，只输出续写正文，不总结。")
                    ]
                    let continuation = try await session.aiClient.complete(profile: profile, apiKey: apiKey, messages: continuationMessages)
                    self.streamedText = TextContinuationMerger.merge(existing: self.streamedText, continuation: continuation.content)
                    self.finishReason = continuation.finishReason
                }

                guard !self.streamedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIClientError.emptyResponse }
                record.status = .completed
                record.completedAt = Date()
                record.outputCharacters = self.streamedText.count
                session.addGenerationRecord(record)
                _ = session.addCandidateVersion(chapterID: chapter.id, body: self.streamedText, source: .generated, profileID: profile.id, generationRecordID: recordID, note: "AI 生成候选，尚未接受")
                self.state = .completed("候选正文已保存，当前正文未被覆盖。")
            } catch {
                record.status = error is CancellationError ? .cancelled : .failed
                record.completedAt = Date()
                record.outputCharacters = self.streamedText.count
                record.errorMessage = error.localizedDescription
                session.addGenerationRecord(record)
                if !self.streamedText.isEmpty {
                    _ = session.addCandidateVersion(chapterID: chapter.id, body: self.streamedText, source: .generated, profileID: profile.id, generationRecordID: recordID, note: "请求中断后保留的部分候选")
                }
                throw error
            }
        }
    }

    func runFourReviews(session: ProjectSession, chapter: ChapterCard) {
        run(label: "运行四类审稿") { [weak self, weak session] in
            guard let self, let session else { return }
            let body = try await session.body(for: chapter)
            guard !body.isEmpty else { throw AIClientError.emptyResponse }
            for (offset, kind) in [ReviewKind.plot, .continuity, .prose, .platform].enumerated() {
                try Task.checkCancellation()
                self.state = .running("\(kind.displayName)（\(offset + 1)/4）")
                let report = try await self.review(kind: kind, body: body, chapter: chapter, session: session)
                session.addReview(report)
            }
            self.state = .completed("四类审稿已完成。")
        }
    }

    func rewrite(session: ProjectSession, chapter: ChapterCard, issueIDs: Set<UUID>) {
        run(label: "定向重写") { [weak self, weak session] in
            guard let self, let session else { return }
            let current = try await session.body(for: chapter)
            guard !current.isEmpty else { throw AIClientError.emptyResponse }
            let selected = session.unresolvedIssues(for: chapter).filter { issueIDs.contains($0.id) }
            guard !selected.isEmpty else { throw WorkflowError.noIssuesSelected }
            let profile = try self.profile(for: .rewriter, session: session)
            let key = try self.key(for: profile, session: session)
            let issueText = selected.map { "- [\($0.severity.rawValue)] \($0.title)：\($0.evidence)；建议：\($0.suggestion)" }.joined(separator: "\n")
            let context = try await self.context(for: chapter, session: session, profile: profile)
            let instruction = """
            只修复以下已选问题，保持其他情节事实、人物状态、视角、章末钩子不变：
            \(issueText)

            原正文：
            \(current)

            输出修订后的完整章节正文，不解释修改过程。
            """
            let messages = PromptCompiler.compile(PromptRequest(task: .rewrite, project: session.workspace.project, instruction: instruction, context: context))
            let result = try await session.aiClient.complete(profile: profile, apiKey: key, messages: messages)
            let record = GenerationRecord(task: PromptTask.rewrite.rawValue, role: .rewriter, modelProfileID: profile.id, templateVersion: PromptCompiler.templateVersion, promptHash: Self.stableHash(messages.map(\.content).joined()), completedAt: Date(), inputCharacters: messages.map(\.content.count).reduce(0, +), outputCharacters: result.content.count, status: .completed)
            session.addGenerationRecord(record)
            _ = session.addCandidateVersion(chapterID: chapter.id, body: result.content, source: .rewritten, profileID: profile.id, generationRecordID: record.id, note: "针对 \(selected.count) 个问题的修订候选")
            self.planningResult = result.content
            self.state = .completed("修订候选已保存，当前正文未被覆盖。")
        }
    }

    func rewriteSelection(session: ProjectSession, chapter: ChapterCard, range: NSRange, instruction: String) {
        run(label: "改写选中段落") { [weak self, weak session] in
            guard let self, let session else { return }
            let current = try await session.body(for: chapter)
            guard let swiftRange = Range(range, in: current), !swiftRange.isEmpty else { throw WorkflowError.noSelection }
            let selection = String(current[swiftRange])
            let profile = try self.profile(for: .rewriter, session: session)
            let key = try self.key(for: profile, session: session)
            let context = try await self.context(for: chapter, session: session, profile: profile)
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
            let record = GenerationRecord(task: "selectionRewrite", role: .rewriter, modelProfileID: profile.id, templateVersion: PromptCompiler.templateVersion, promptHash: Self.stableHash(messages.map(\.content).joined()), completedAt: Date(), inputCharacters: messages.map(\.content.count).reduce(0, +), outputCharacters: result.content.count, status: .completed)
            session.addGenerationRecord(record)
            _ = session.addCandidateVersion(chapterID: chapter.id, body: revised, source: .rewritten, profileID: profile.id, generationRecordID: record.id, note: "选段改写：\(instruction)")
            self.state = .completed("选段改写候选已保存，当前正文未被覆盖。")
        }
    }

    func extractCandidateFacts(session: ProjectSession, chapter: ChapterCard) {
        run(label: "提取连续性事实") { [weak self, weak session] in
            guard let self, let session else { return }
            let body = try await session.body(for: chapter)
            guard !body.isEmpty else { throw AIClientError.emptyResponse }
            let profile = try self.profile(for: .memoryExtractor, session: session)
            let key = try self.key(for: profile, session: session)
            let acceptedFacts = session.workspace.facts.filter { $0.status == .accepted }.map { "\($0.subject)|\($0.predicate)|\($0.value)" }.joined(separator: "\n")
            let instruction = """
            从本章正文提取会影响后续连续性的明确事实。只记录人物状态、物品归属、地点、时间、关系、能力和伏笔变化。对照正式事实标记可能冲突，但不要自行裁决。
            正式事实：
            \(acceptedFacts.isEmpty ? "暂无" : acceptedFacts)
            本章正文：
            \(body)
            """
            let schema = "{\"facts\":[{\"subject\":\"\",\"predicate\":\"\",\"value\":\"\",\"conflict_with_fact_id\":null}]}"
            let context = try await self.context(for: chapter, session: session, profile: profile)
            let messages = PromptCompiler.compile(PromptRequest(task: .extractFacts, project: session.workspace.project, instruction: instruction, context: context, outputSchema: schema))
            let completion = try await self.completeJSON(profile: profile, key: key, messages: messages, session: session)
            let payload = try JSONDecoder().decode(FactsPayload.self, from: Data(PromptCompiler.stripMarkdownCodeFence(completion).utf8))
            let facts = payload.facts.compactMap { item -> ContinuityFact? in
                guard !item.subject.isEmpty, !item.predicate.isEmpty, !item.value.isEmpty else { return nil }
                return ContinuityFact(chapterID: chapter.id, subject: item.subject, predicate: item.predicate, value: item.value, status: .candidate, conflictWithFactID: item.conflictWithFactID)
            }
            session.addCandidateFacts(facts)
            self.state = .completed("提取了 \(facts.count) 条候选事实；只有章节批准后才会入正式台账。")
        }
    }

    func runRegressionReview(session: ProjectSession) {
        run(label: "跨章回归审稿") { [weak self, weak session] in
            guard let self, let session else { return }
            let approved = session.sortedChapters.filter { $0.status == .approved }
            guard !approved.isEmpty else { throw WorkflowError.noApprovedChapters }
            let chapters = Array(approved.suffix(10))
            let profile = try self.profile(for: .reviewer, session: session)
            let key = try self.key(for: profile, session: session)
            let platform = session.settings.platformProfile(for: session.workspace.project.platform)
            let dimensions = platform.weights.keys.map(\.rawValue).sorted().joined(separator: ", ")
            var manuscriptParts: [String] = []
            for chapter in chapters {
                let body = try await session.body(for: chapter)
                manuscriptParts.append("# 第\(chapter.number)章 \(chapter.title)\n摘要：\(chapter.summary)\n正文：\(body)")
            }
            let manuscript = manuscriptParts.joined(separator: "\n\n")
            let instruction = """
            对以下最近 \(chapters.count) 个已批准章节做跨章回归审稿。重点检查人物状态漂移、力量体系冲突、重复剧情、长期目标停滞、遗忘伏笔和时间线错误，并按这些维度评分：\(dimensions)。
            \(manuscript)
            """
            let schema = "{\"scores\":{\"dimension_key\":0},\"issues\":[{\"severity\":\"info|low|medium|high|critical\",\"dimension\":\"dimension_key\",\"title\":\"\",\"evidence\":\"\",\"suggestion\":\"\"}],\"summary\":\"\"}"
            let context = self.generalContext(session: session, profile: profile)
            let messages = PromptCompiler.compile(PromptRequest(task: .review, project: session.workspace.project, instruction: instruction, context: context, outputSchema: schema))
            let output = try await self.completeJSON(profile: profile, key: key, messages: messages, session: session)
            let payload = try JSONDecoder().decode(ReviewPayload.self, from: Data(PromptCompiler.stripMarkdownCodeFence(output).utf8))
            let scores = Dictionary(uniqueKeysWithValues: payload.scores.compactMap { key, value in QualityDimension(rawValue: key).map { ($0, value) } })
            let issues = payload.issues.compactMap { item -> ReviewIssue? in
                guard let severity = ReviewSeverity(rawValue: item.severity), let dimension = QualityDimension(rawValue: item.dimension) else { return nil }
                return ReviewIssue(severity: severity, dimension: dimension, title: item.title, evidence: item.evidence, suggestion: item.suggestion)
            }
            session.addReview(ReviewReport(chapterID: nil, kind: .regression, scores: scores, issues: issues, summary: payload.summary, reviewerProfileID: profile.id))
            self.state = .completed("最近 \(chapters.count) 个已批准章节的回归审稿已完成。")
        }
    }

    private func review(kind: ReviewKind, body: String, chapter: ChapterCard, session: ProjectSession) async throws -> ReviewReport {
        let profile = try profile(for: .reviewer, session: session)
        let key = try key(for: profile, session: session)
        let platform = session.settings.platformProfile(for: session.workspace.project.platform)
        let dimensions = platform.weights.keys.map(\.rawValue).sorted().joined(separator: ", ")
        let instruction = """
        以“\(kind.displayName)”身份审查第\(chapter.number)章。逐项给出 0-100 分；必须引用正文证据，不因文笔流畅而忽略事实冲突。
        必须评分的维度：\(dimensions)
        正文：
        \(body)
        """
        let schema = "{\"scores\":{\"dimension_key\":0},\"issues\":[{\"severity\":\"info|low|medium|high|critical\",\"dimension\":\"dimension_key\",\"title\":\"\",\"evidence\":\"\",\"suggestion\":\"\"}],\"summary\":\"\"}"
        let context = try await context(for: chapter, session: session, profile: profile, includePreviousChapter: false)
        let messages = PromptCompiler.compile(PromptRequest(task: .review, project: session.workspace.project, instruction: instruction, context: context, outputSchema: schema))
        let output = try await completeJSON(profile: profile, key: key, messages: messages, session: session)
        let payload = try JSONDecoder().decode(ReviewPayload.self, from: Data(PromptCompiler.stripMarkdownCodeFence(output).utf8))
        let scores = Dictionary(uniqueKeysWithValues: payload.scores.compactMap { key, value in
            QualityDimension(rawValue: key).map { ($0, value) }
        })
        let issues = payload.issues.compactMap { item -> ReviewIssue? in
            guard let severity = ReviewSeverity(rawValue: item.severity), let dimension = QualityDimension(rawValue: item.dimension) else { return nil }
            return ReviewIssue(severity: severity, dimension: dimension, title: item.title, evidence: item.evidence, suggestion: item.suggestion)
        }
        return ReviewReport(chapterID: chapter.id, chapterVersionID: chapter.activeVersionID, kind: kind, scores: scores, issues: issues, summary: payload.summary, reviewerProfileID: profile.id)
    }

    private func completePlanning(task: PromptTask, instruction: String, chapter: ChapterCard? = nil, session: ProjectSession) async throws -> String {
        let profile = try profile(for: .planner, session: session)
        let key = try key(for: profile, session: session)
        let context: ContextSelection
        if let chapter {
            context = try await self.context(for: chapter, session: session, profile: profile)
        } else {
            context = generalContext(session: session, profile: profile)
        }
        let messages = PromptCompiler.compile(PromptRequest(task: task, project: session.workspace.project, instruction: instruction, context: context))
        let completion = try await session.aiClient.complete(profile: profile, apiKey: key, messages: messages)
        let record = GenerationRecord(task: task.rawValue, role: .planner, modelProfileID: profile.id, templateVersion: PromptCompiler.templateVersion, promptHash: Self.stableHash(messages.map(\.content).joined()), completedAt: Date(), inputCharacters: messages.map(\.content.count).reduce(0, +), outputCharacters: completion.content.count, status: .completed)
        session.addGenerationRecord(record)
        let artifact = PlanningArtifact(task: task, chapterID: chapter?.id, content: completion.content, modelProfileID: profile.id, generationRecordID: record.id)
        session.addPlanningArtifact(artifact)
        latestPlanningArtifactID = artifact.id
        return completion.content
    }

    private func completeJSON(profile: AIEndpointProfile, key: String, messages: [ChatMessage], session: ProjectSession) async throws -> String {
        let first = try await session.aiClient.complete(profile: profile, apiKey: key, messages: messages)
        let cleaned = PromptCompiler.stripMarkdownCodeFence(first.content)
        if (try? JSONSerialization.jsonObject(with: Data(cleaned.utf8))) != nil { return cleaned }
        let repair = messages + [
            ChatMessage(role: "assistant", content: first.content),
            ChatMessage(role: "user", content: "上一个结果不是合法 JSON。只修复格式并完整输出一个合法 JSON；不得添加解释或 Markdown 围栏。")
        ]
        return try await session.aiClient.complete(profile: profile, apiKey: key, messages: repair).content
    }

    private func profile(for role: AIRole, session: ProjectSession) throws -> AIEndpointProfile {
        guard let profile = session.settings.profile(for: role) else { throw WorkflowError.missingProfile(role.displayName) }
        guard profile.isSecure else { throw AIClientError.insecureEndpoint }
        return profile
    }

    private func key(for profile: AIEndpointProfile, session: ProjectSession) throws -> String {
        guard let key = try session.settings.keychain.value(for: profile.keychainReference), !key.isEmpty else { throw AIClientError.missingKey }
        return key
    }

    private func generalContext(session: ProjectSession, profile: AIEndpointProfile) -> ContextSelection {
        let items = baseContextItems(session: session)
        return ContextBuilder.select(from: items, contextLimit: profile.contextTokenLimit, outputReserve: profile.outputTokenLimit)
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
            for previous in sorted.prefix(currentIndex).dropLast() where !previous.summary.isEmpty {
                let relevance = ContextBuilder.relevance(of: previous.summary, to: chapterText)
                items.append(ContextItem(id: "summary-\(previous.id)", category: .earlierSummary, title: "第\(previous.number)章摘要", text: previous.summary, priority: 30, relevance: relevance))
            }
            items.append(contentsOf: try await session.searchHistoricalPassages(before: chapter, query: chapterText))
        }
        return ContextBuilder.select(from: items, contextLimit: profile.contextTokenLimit, outputReserve: profile.outputTokenLimit)
    }

    private func baseContextItems(session: ProjectSession) -> [ContextItem] {
        let bible = session.workspace.bible
        var items = [ContextItem(
            id: "bible",
            category: .storyBible,
            title: "已批准故事圣经",
            text: "前提：\(bible.premise)\n主题：\(bible.themes.joined(separator: "、"))\n中央冲突：\(bible.centralConflict)\n终局承诺：\(bible.endingPromise)\n文风：\(bible.styleGuide)\n禁忌：\(bible.forbiddenPatterns.joined(separator: "、"))",
            priority: 100,
            required: true
        )]
        let rules = session.workspace.worldRules.map { "[\($0.category)] \($0.title)：\($0.detail)" }.joined(separator: "\n")
        if !rules.isEmpty { items.append(ContextItem(id: "world-rules", category: .storyBible, title: "世界硬规则", text: rules, priority: 95, required: true)) }
        if let style = session.workspace.styleProfile {
            items.append(ContextItem(id: "style", category: .instruction, title: "自有样章抽象风格", text: "平均句长 \(Int(style.averageSentenceLength))；对话比例 \(Int(style.dialogueRatio * 100))%；平均段长 \(Int(style.paragraphLength))；视角 \(style.perspective.displayName)。", priority: 70))
        }
        return items
    }

    private func run(label: String, operation: @escaping @MainActor () async throws -> Void) {
        task?.cancel()
        streamedText = ""
        finishReason = nil
        state = .running(label)
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil }
            do {
                try await operation()
                if case .running = self.state { self.state = .completed("已完成") }
            } catch is CancellationError {
                self.state = .cancelled
            } catch {
                self.state = .failed(error.localizedDescription)
                await DiagnosticLogger.shared.log(category: "Workflow", message: error.localizedDescription)
            }
        }
    }

    private static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

private enum WorkflowError: LocalizedError {
    case missingProfile(String)
    case noIssuesSelected
    case noApprovedChapters
    case noSelection

    var errorDescription: String? {
        switch self {
        case .missingProfile(let role): return "请先在设置中为“\(role)”配置模型。"
        case .noIssuesSelected: return "请至少选择一个待修复问题。"
        case .noApprovedChapters: return "至少需要一个已批准章节才能运行跨章回归审稿。"
        case .noSelection: return "请先在正文中选择需要改写的文字。"
        }
    }
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
