import Foundation
import Combine
import NovelCore

@MainActor
final class WritingAgentController: ObservableObject {
    enum State: Equatable {
        case idle
        case thinking
        case running(String)
        case waiting(String)
        case paused
        case completed(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var streamedDraft = ""

    let session: ProjectSession
    let executor: WorkflowToolExecutor
    private let indexStore: ManuscriptIndexStore
    private var task: Task<Void, Never>?

    init(session: ProjectSession, executor: WorkflowToolExecutor, indexStore: ManuscriptIndexStore = .live()) {
        self.session = session
        self.executor = executor
        self.indexStore = indexStore
        seedConversationIfNeeded()
        restoreInterruptedRun()
    }

    var messages: [AgentMessage] { session.workspace.agentSession.messages }
    var pendingApprovals: [ApprovalRequest] {
        session.workspace.agentSession.approvals.filter { $0.status == .pending }
    }
    var activeRun: AgentRun? {
        guard let id = session.workspace.agentSession.activeRunID else { return nil }
        return session.workspace.agentSession.runs.first { $0.id == id }
    }

    func setPolicy(_ policy: AgentPolicy) {
        session.setAgentPolicy(policy)
    }

    func send(_ content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, task == nil else { return }
        guard trimmed.count <= 12_000 else {
            state = .failed("单条消息最多 12,000 字；长篇小说请使用附件分析工具。")
            return
        }
        session.appendAgentMessage(AgentMessage(role: .user, content: trimmed))
        state = .thinking
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil }
            do {
                let response = try await self.requestAgentResponse()
                self.session.appendAgentMessage(AgentMessage(role: .assistant, content: response.reply))
                if let proposal = response.proposal {
                    let patch = self.makePlanningPatch(from: proposal)
                    try self.createPlanApproval(for: patch)
                    self.state = .waiting("请确认结构化方案")
                } else {
                    self.state = .idle
                }
            } catch is CancellationError {
                self.state = .paused
            } catch {
                self.state = .failed(error.localizedDescription)
                self.session.appendAgentMessage(AgentMessage(role: .system, kind: .report, content: "请求失败：\(error.localizedDescription)"))
                await DiagnosticLogger.shared.log(category: "Agent", message: error.localizedDescription)
                await self.appendAutomaticHealthSummary()
            }
        }
    }

    func approve(_ request: ApprovalRequest) {
        do {
            switch request.kind {
            case .projectPlan, .storyBible, .volumeOutline:
                guard let payload = request.payload?.data(using: .utf8) else { throw AgentControllerError.invalidApprovalPayload }
                let patch = try JSONDecoder.iso8601.decode(ProjectPlanPatch.self, from: payload)
                try session.applyPlanningPatch(patch)
                session.resolveApproval(id: request.id, status: .approved)
                session.appendAgentMessage(AgentMessage(role: .assistant, kind: .progress, content: "方案已写入工程。后续修改会基于 revision \(session.workspace.project.planRevision) 继续。", relatedApprovalID: request.id))
                state = .idle
            case .runScope:
                session.resolveApproval(id: request.id, status: .approved)
                resumeRun()
            case .chapterApproval:
                try approveChapterMilestone(request)
            case .blocker:
                session.resolveApproval(id: request.id, status: .approved)
                if let payload = request.payload, payload.hasPrefix("reject-conflicts:"),
                   let chapterID = UUID(uuidString: String(payload.dropFirst("reject-conflicts:".count))) {
                    session.rejectConflictingCandidateFacts(chapterID: chapterID)
                    resumeRelatedRun(request)
                } else {
                    markRelatedRunPaused(request)
                }
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func requestRevision(_ request: ApprovalRequest) {
        session.resolveApproval(id: request.id, status: .revisionRequested)
        session.appendAgentMessage(AgentMessage(role: .assistant, content: "已保留原方案但不会应用。请告诉我需要修改的部分。", relatedApprovalID: request.id))
        if request.kind == .runScope {
            cancelRelatedRun(request)
        } else if request.kind == .chapterApproval {
            rewindRelatedRunForReview(request)
        } else if request.relatedRunID != nil {
            markRelatedRunPaused(request)
        } else {
            state = .idle
        }
    }

    func startRun(scope: RunScope) {
        guard task == nil, activeRun == nil else {
            state = .failed("已有未完成任务，请先恢复或取消。")
            return
        }
        do {
            let chapterIDs = try resolveChapterIDs(scope: scope)
            let policy = session.workspace.agentSession.policy
            let steps = chapterIDs.flatMap(makeSteps)
            let maximumCalls = max(1, chapterIDs.count * 32)
            let run = AgentRun(policy: policy, scope: scope, chapterIDs: chapterIDs, steps: steps, maximumModelCalls: maximumCalls)
            session.upsertAgentRun(run)
            let summary = "范围：\(scope.displayName)；预计最多 \(maximumCalls) 次模型调用；每章最多自动修订两轮。"
            let approval = ApprovalRequest(kind: .runScope, title: "确认执行任务", summary: summary, relatedRunID: run.id)
            session.addApprovalRequest(approval)
            session.appendAgentMessage(AgentMessage(role: .assistant, kind: .approval, content: summary, relatedRunID: run.id, relatedApprovalID: approval.id))
            state = .waiting("等待确认执行范围")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func pause() {
        let hadTask = task != nil
        let hadRun = activeRun != nil
        guard hadTask || hadRun else { return }
        task?.cancel()
        if var run = activeRun, run.status == .running {
            run.status = .paused
            run.updatedAt = Date()
            if run.currentStepIndex < run.steps.count, run.steps[run.currentStepIndex].status == .running {
                run.steps[run.currentStepIndex].status = .pending
                run.steps[run.currentStepIndex].detail = "应用离开前台，等待恢复"
            }
            session.upsertAgentRun(run)
        }
        state = .paused
    }

    func pauseAndFlush() async {
        let currentTask = task
        pause()
        await currentTask?.value
        await session.flushSave()
    }

    func resumeRun() {
        guard task == nil, var run = activeRun else { return }
        run.status = .running
        run.updatedAt = Date()
        session.upsertAgentRun(run)
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil }
            await self.executeActiveRun()
        }
    }

    func cancelRun() {
        task?.cancel()
        if var run = activeRun {
            run.status = .cancelled
            run.updatedAt = Date()
            session.upsertAgentRun(run)
        }
        state = .idle
    }

    private func requestAgentResponse() async throws -> AgentModelResponse {
        let project = session.workspace.project
        let templateNames = session.settings.writingTemplates.map(\.name).joined(separator: "、")
        let system = """
        你是专门协助新手创作中文长篇小说的写作 Agent。通过多轮对话逐步确认设定，不要求用户理解专业工作流。
        当前工程 revision：\(project.planRevision)。作品名：\(project.title)。
        当前资料：题材 \(project.genre)；平台 \(project.platform.displayName)；卖点 \(project.sellingPoint.isEmpty ? "待确认" : project.sellingPoint)；主角目标 \(project.protagonistGoal.isEmpty ? "待确认" : project.protagonistGoal)。
        可选全局模板：\(templateNames.isEmpty ? "暂无" : templateNames)。

        规则：
        1. 每轮优先询问一到三个最关键问题，避免一次抛出专业表单。
        2. 信息足够时返回结构化 proposal，baseRevision 必须为 \(project.planRevision)。
        3. 未经确认不把候选当作正式设定，不请求删除、导出、覆盖历史版本等工具。
        4. toolRequests 只能使用白名单：\(AgentTool.allCases.map(\.rawValue).joined(separator: ","))。
        5. 只输出一个合法 JSON，不使用 Markdown 围栏。结构：
        {"reply":"给用户的中文回复","proposal":null或{"baseRevision":\(project.planRevision),"title":"","platform":"qidian|fanqie","genre":"","sellingPoint":"","targetWordCount":1000000,"protagonistGoal":"","restrictedContent":[],"perspective":"thirdPersonLimited|firstPerson|omniscient","targetChapterWords":2500,"selectedTemplateID":"模板UUID","clearAppliedTemplate":false,"bible":{"premise":"","themes":[],"centralConflict":"","endingPromise":"","styleGuide":"","forbiddenPatterns":[]},"characters":[{"name":"","role":"","desire":"","fear":"","flaw":"","arc":"","voice":"","currentState":""}],"worldRules":[{"category":"","title":"","detail":"","immutable":true}],"volumes":[{"number":1,"title":"","goal":"","climax":"","resolution":""}],"chapters":[{"number":1,"title":"","goal":"","conflict":"","turn":"","hook":"","summary":""}]},"toolRequests":[{"tool":"readProjectSummary","arguments":{}}]}
        proposal 中无需修改的字段不要输出；不要输出 UUID、日期、版本状态或正文。
        """
        for round in 0..<3 {
            let history = messages.suffix(30).map { message -> ChatMessage in
                let role: String
                switch message.role {
                case .user: role = "user"
                case .tool: role = "user"
                case .assistant, .system: role = "assistant"
                }
                let prefix = message.role == .tool ? "工具结果：" : ""
                return ChatMessage(role: role, content: prefix + message.content)
            }
            let prompt = [ChatMessage(role: "system", content: system)] + history
            let response = try await decodeAgentResponse(prompt: prompt)
            let requests = response.toolRequests
            if requests.isEmpty || round == 2 { return response }
            if !response.reply.isEmpty {
                session.appendAgentMessage(AgentMessage(role: .assistant, content: response.reply))
            }
            for request in requests.prefix(5) {
                let result = await executeReadOnlyTool(request)
                session.appendAgentMessage(AgentMessage(role: .tool, kind: .progress, content: "\(request.tool.rawValue)：\(result)"))
            }
        }
        throw AgentResponseParserError.invalidJSON
    }

    private func decodeAgentResponse(prompt: [ChatMessage]) async throws -> AgentModelResponse {
        let first = try await executor.completeAgent(messages: prompt, session: session)
        if let response = try? AgentResponseParser.decode(first) { return response }
        let repair = prompt + [
            ChatMessage(role: "assistant", content: first),
            ChatMessage(role: "user", content: "上一个结果不是合法的指定 JSON。只修复格式，完整输出 JSON，不要解释。")
        ]
        let second = try await executor.completeAgent(messages: repair, session: session)
        return try AgentResponseParser.decode(second)
    }

    private func executeReadOnlyTool(_ request: AgentToolRequest) async -> String {
        switch request.tool {
        case .readProjectSummary:
            let project = session.workspace.project
            return "revision=\(project.planRevision)，题材=\(project.genre)，章节=\(session.sortedChapters.count)，已批准=\(session.sortedChapters.filter { $0.status == .approved }.count)"
        case .listTemplates:
            let values = session.settings.writingTemplates.map { "\($0.id.uuidString)|\($0.name)|置信度\(Int($0.confidence * 100))%" }
            return values.isEmpty ? "无可用模板" : values.joined(separator: "；")
        case .evaluateQualityGate:
            guard let chapter = session.selectedChapter else { return "当前没有章节" }
            let result = session.qualityGateResult(for: chapter)
            return "综合分 \(String(format: "%.1f", result.totalScore))，通过=\(result.passed)，阻断问题=\(result.blockingIssues.count)"
        case .queryManuscriptIndex:
            let hash = request.arguments["sourceHash"] ?? session.workspace.appliedTemplate?.template.sourceHash
            guard let hash, let index = try? await indexStore.load(sourceHash: hash) else { return "未找到对应长篇索引" }
            let query = request.arguments["query"] ?? ""
            let matches = index.nodes.filter { query.isEmpty || $0.label.localizedCaseInsensitiveContains(query) }
                .sorted { $0.frequency > $1.frequency }.prefix(12)
            return matches.map { "\($0.label)(\($0.frequency))" }.joined(separator: "、")
        case .runHealthCheck:
            let report = await HealthCheckRunner(indexStore: indexStore).run(session: session, settings: session.settings)
            return "失败 \(report.checks.filter { $0.status == .failed }.count) 项，警告 \(report.checks.filter { $0.status == .warning }.count) 项"
        default:
            return "该工具会修改工程，只能在用户确认方案或执行范围后运行"
        }
    }

    private func createPlanApproval(for patch: ProjectPlanPatch) throws {
        guard patch.baseRevision == session.workspace.project.planRevision else {
            throw AgentControllerError.staleProposal
        }
        let data = try JSONEncoder.iso8601.encode(patch)
        let summary = summarize(patch)
        let request = ApprovalRequest(kind: .projectPlan, title: "确认小说方案", summary: summary, payload: String(decoding: data, as: UTF8.self))
        session.addApprovalRequest(request)
        session.appendAgentMessage(AgentMessage(role: .assistant, kind: .proposal, content: summary, relatedApprovalID: request.id))
    }

    private func summarize(_ patch: ProjectPlanPatch) -> String {
        var values: [String] = []
        if let title = patch.title { values.append("作品：\(title)") }
        if let genre = patch.genre { values.append("题材：\(genre)") }
        if let point = patch.sellingPoint { values.append("核心卖点：\(point)") }
        if let goal = patch.protagonistGoal { values.append("主角目标：\(goal)") }
        if let bible = patch.bible { values.append("故事前提：\(bible.premise)") }
        if let count = patch.characters?.count { values.append("人物：\(count) 名") }
        if let count = patch.volumes?.count { values.append("卷纲：\(count) 卷") }
        if let count = patch.chapters?.count { values.append("章卡：\(count) 章") }
        if let templateID = patch.selectedTemplateID,
           let template = session.settings.writingTemplates.first(where: { $0.id == templateID }) {
            values.append("写作模板：\(template.name)")
        } else if patch.clearAppliedTemplate == true {
            values.append("写作模板：不使用模板")
        }
        return values.isEmpty ? "Agent 提交了一项结构化工程更新。" : values.joined(separator: "\n")
    }

    private func makePlanningPatch(from proposal: AgentPlanProposal) -> ProjectPlanPatch {
        var patch = ProjectPlanPatch(baseRevision: proposal.baseRevision)
        patch.title = proposal.title
        patch.platform = proposal.platform
        patch.genre = proposal.genre
        patch.sellingPoint = proposal.sellingPoint
        patch.targetWordCount = proposal.targetWordCount
        patch.protagonistGoal = proposal.protagonistGoal
        patch.restrictedContent = proposal.restrictedContent
        patch.perspective = proposal.perspective
        patch.targetChapterWords = proposal.targetChapterWords
        patch.selectedTemplateID = proposal.selectedTemplateID
        patch.clearAppliedTemplate = proposal.clearAppliedTemplate
        if let value = proposal.bible {
            let current = session.workspace.bible
            patch.bible = StoryBible(
                premise: value.premise ?? current.premise,
                themes: value.themes ?? current.themes,
                centralConflict: value.centralConflict ?? current.centralConflict,
                endingPromise: value.endingPromise ?? current.endingPromise,
                styleGuide: value.styleGuide ?? current.styleGuide,
                forbiddenPatterns: value.forbiddenPatterns ?? current.forbiddenPatterns
            )
        }
        if let values = proposal.characters {
            patch.characters = values.compactMap { value in
                guard let name = value.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
                return NovelCore.Character(name: name, role: value.role ?? "", desire: value.desire ?? "", fear: value.fear ?? "", flaw: value.flaw ?? "", arc: value.arc ?? "", voice: value.voice ?? "", currentState: value.currentState ?? "")
            }
        }
        if let values = proposal.worldRules {
            patch.worldRules = values.compactMap { value in
                guard let title = value.title, let detail = value.detail, !title.isEmpty, !detail.isEmpty else { return nil }
                return WorldRule(category: value.category ?? "世界规则", title: title, detail: detail, immutable: value.immutable ?? true)
            }
        }
        if let values = proposal.volumes {
            patch.volumes = values.enumerated().compactMap { offset, value in
                guard let title = value.title, !title.isEmpty else { return nil }
                return VolumeOutline(number: value.number ?? offset + 1, title: title, goal: value.goal ?? "", climax: value.climax ?? "", resolution: value.resolution ?? "")
            }
        }
        if let values = proposal.chapters {
            patch.chapters = values.enumerated().map { offset, value in
                let number = value.number ?? offset + 1
                return ChapterCard(number: number, title: value.title ?? "第\(number)章", goal: value.goal ?? "", conflict: value.conflict ?? "", turn: value.turn ?? "", hook: value.hook ?? "", summary: value.summary ?? "", status: .planned)
            }
        }
        return patch
    }

    private func resolveChapterIDs(scope: RunScope) throws -> [UUID] {
        guard let selected = session.selectedChapter ?? session.sortedChapters.first else { throw AgentControllerError.noChapter }
        switch scope {
        case .currentChapter:
            return [selected.id]
        case .chapterCount(let requested):
            let count = min(20, max(1, requested))
            let sorted = session.sortedChapters
            let start = sorted.firstIndex(where: { $0.id == selected.id }) ?? 0
            let ids = Array(sorted.dropFirst(start).prefix(count).map(\.id))
            guard ids.count == count else {
                throw AgentControllerError.insufficientChapters(requested: count, available: ids.count)
            }
            return ids
        case .currentVolume:
            guard let volumeID = selected.volumeID else { return [selected.id] }
            let ids = session.sortedChapters.filter { $0.volumeID == volumeID }.map(\.id)
            return ids.isEmpty ? [selected.id] : ids
        }
    }

    private func makeSteps(chapterID: UUID) -> [AgentStep] {
        [
            AgentStep(tool: .manageChapterCard, title: "检查章卡", chapterID: chapterID),
            AgentStep(tool: .generateDraft, title: "生成正文候选", chapterID: chapterID),
            AgentStep(tool: .acceptCandidate, title: "采用待审候选", chapterID: chapterID),
            AgentStep(tool: .runReviews, title: "运行四类审稿", chapterID: chapterID),
            AgentStep(tool: .rewriteIssues, title: "按问题修订", chapterID: chapterID),
            AgentStep(tool: .extractFacts, title: "提取连续性事实", chapterID: chapterID),
            AgentStep(tool: .evaluateQualityGate, title: "检查质量门禁", chapterID: chapterID),
            AgentStep(tool: .approveChapter, title: "批准章节", chapterID: chapterID)
        ]
    }

    private func executeActiveRun() async {
        do {
            while var run = activeRun, run.currentStepIndex < run.steps.count {
                try Task.checkCancellation()
                let index = run.currentStepIndex
                let step = run.steps[index]
                guard let chapterID = step.chapterID,
                      let chapter = session.workspace.chapters.first(where: { $0.id == chapterID }) else {
                    throw AgentControllerError.noChapter
                }
                run.status = .running
                run.steps[index].status = .running
                run.steps[index].startedAt = Date()
                if step.tool != .rewriteIssues { run.steps[index].attempt += 1 }
                run.updatedAt = Date()
                session.upsertAgentRun(run)
                state = .running("第 \(chapter.number) 章 · \(step.title)")

                let outcome = try await execute(step: step, chapter: chapter, run: &run)
                if outcome == .paused {
                    session.upsertAgentRun(run)
                    return
                }
                run.steps[index].status = outcome == .skipped ? .skipped : .completed
                run.steps[index].completedAt = Date()
                run.currentStepIndex += 1
                run.updatedAt = Date()
                session.upsertAgentRun(run)
            }

            if var run = activeRun {
                run.status = .completed
                run.updatedAt = Date()
                session.upsertAgentRun(run)
                session.appendAgentMessage(AgentMessage(role: .assistant, kind: .progress, content: "执行范围“\(run.scope.displayName)”已完成，Agent 已按约定停止。", relatedRunID: run.id))
                state = .completed("任务已完成")
            }
        } catch is CancellationError {
            if session.workspace.agentSession.activeRunID == nil {
                state = .idle
            } else {
                pause()
            }
        } catch {
            blockActiveRun(message: error.localizedDescription)
            await DiagnosticLogger.shared.log(category: "AgentRun", message: error.localizedDescription)
            await appendAutomaticHealthSummary()
        }
    }

    private enum StepOutcome { case completed, skipped, paused }

    private func execute(step: AgentStep, chapter: ChapterCard, run: inout AgentRun) async throws -> StepOutcome {
        switch step.tool {
        case .manageChapterCard:
            if chapter.goal.isEmpty || chapter.conflict.isEmpty || chapter.hook.isEmpty {
                try consumeCalls(2, run: &run)
                _ = try await executor.prepareChapterCard(session: session, chapter: chapter)
            }
            return .completed

        case .generateDraft:
            try consumeCalls(2, run: &run)
            streamedDraft = ""
            _ = try await executor.generateDraft(session: session, chapter: chapter) { [weak self] text, _ in self?.streamedDraft = text }
            return .completed

        case .acceptCandidate:
            if let active = session.activeVersion(for: chapter),
               active.approvedAt == nil,
               active.source == .generated || active.source == .rewritten {
                return .completed
            }
            guard let candidate = session.candidateVersions(for: chapter).max(by: { $0.createdAt < $1.createdAt }) else { throw AgentControllerError.noCandidate }
            session.acceptVersion(chapterID: chapter.id, versionID: candidate.id)
            return .completed

        case .runReviews:
            guard let current = session.workspace.chapters.first(where: { $0.id == chapter.id }) else { throw AgentControllerError.noChapter }
            let existing = Set(session.reviews(for: current).map(\.kind))
            let missing = [ReviewKind.plot, .continuity, .prose, .platform].filter { !existing.contains($0) }
            if missing.isEmpty { return .skipped }
            try consumeCalls(missing.count * 2, run: &run)
            _ = try await executor.runReviews(session: session, chapter: current, kinds: missing)
            return .completed

        case .rewriteIssues:
            var rounds = run.steps[run.currentStepIndex].attempt
            while rounds < 2 {
                guard let current = session.workspace.chapters.first(where: { $0.id == chapter.id }) else { throw AgentControllerError.noChapter }
                let requiredKinds: Set<ReviewKind> = [.plot, .continuity, .prose, .platform]
                let currentKinds = Set(session.reviews(for: current).map(\.kind))
                if !requiredKinds.isSubset(of: currentKinds) {
                    let missing = [ReviewKind.plot, .continuity, .prose, .platform].filter { !currentKinds.contains($0) }
                    try consumeCalls(missing.count * 2, run: &run)
                    _ = try await executor.runReviews(session: session, chapter: current, kinds: missing)
                }
                let selectedIssues = session.unresolvedIssues(for: current).filter { $0.severity.rank >= ReviewSeverity.medium.rank }
                if selectedIssues.isEmpty { return rounds == 0 ? .skipped : .completed }
                try consumeCalls(9, run: &run)
                let candidate = try await executor.rewrite(session: session, chapter: current, issueIDs: Set(selectedIssues.map(\.id)))
                session.acceptVersion(chapterID: current.id, versionID: candidate.id)
                rounds += 1
                run.steps[run.currentStepIndex].attempt = rounds
                session.upsertAgentRun(run)
                guard let revised = session.workspace.chapters.first(where: { $0.id == chapter.id }) else { throw AgentControllerError.noChapter }
                _ = try await executor.runReviews(session: session, chapter: revised)
            }
            guard let current = session.workspace.chapters.first(where: { $0.id == chapter.id }) else { throw AgentControllerError.noChapter }
            let remaining = session.unresolvedIssues(for: current).filter { $0.severity.rank >= ReviewSeverity.high.rank }
            if !remaining.isEmpty {
                throw AgentControllerError.revisionLimitReached(remaining.count)
            }
            return .completed

        case .extractFacts:
            try consumeCalls(2, run: &run)
            guard let current = session.workspace.chapters.first(where: { $0.id == chapter.id }) else { throw AgentControllerError.noChapter }
            _ = try await executor.extractFacts(session: session, chapter: current)
            return .completed

        case .evaluateQualityGate:
            guard let current = session.workspace.chapters.first(where: { $0.id == chapter.id }) else { throw AgentControllerError.noChapter }
            let conflicts = session.workspace.facts.filter { $0.chapterID == current.id && $0.status == .candidate && $0.conflictWithFactID != nil }
            if !conflicts.isEmpty {
                let request = ApprovalRequest(
                    kind: .blocker,
                    title: "连续性事实冲突",
                    summary: "发现 \(conflicts.count) 条候选事实与正式台账冲突。确认将拒绝这些冲突候选事实并继续；要求修改会暂停任务。",
                    relatedRunID: run.id,
                    payload: "reject-conflicts:\(current.id.uuidString)"
                )
                session.addApprovalRequest(request)
                session.appendAgentMessage(AgentMessage(role: .assistant, kind: .approval, content: request.summary, relatedRunID: run.id, relatedApprovalID: request.id))
                run.status = .waitingForApproval
                run.steps[run.currentStepIndex].status = .blocked
                state = .waiting("等待处理连续性事实冲突")
                return .paused
            }
            let result = session.qualityGateResult(for: current)
            guard result.passed else { throw AgentControllerError.qualityGateFailed(result.blockingIssues.count) }
            return .completed

        case .approveChapter:
            if run.policy == .supervised {
                let request = ApprovalRequest(kind: .chapterApproval, title: "确认第 \(chapter.number) 章定稿", summary: "四类审稿和质量门禁均已通过。确认后批准当前版本并将无冲突事实写入正式台账。", relatedRunID: run.id, payload: chapter.id.uuidString)
                session.addApprovalRequest(request)
                session.appendAgentMessage(AgentMessage(role: .assistant, kind: .approval, content: request.summary, relatedRunID: run.id, relatedApprovalID: request.id))
                run.status = .waitingForApproval
                run.steps[run.currentStepIndex].status = .blocked
                state = .waiting("等待章节定稿确认")
                return .paused
            }
            let result = session.approveChapter(chapterID: chapter.id)
            guard result?.passed == true else { throw AgentControllerError.qualityGateFailed(result?.blockingIssues.count ?? 0) }
            return .completed

        default:
            throw AgentControllerError.toolNotRunnable(step.tool.rawValue)
        }
    }

    private func consumeCalls(_ count: Int, run: inout AgentRun) throws {
        guard run.modelCallsUsed + count <= run.maximumModelCalls else { throw AgentControllerError.callBudgetReached }
        run.modelCallsUsed += count
        run.updatedAt = Date()
        session.upsertAgentRun(run)
    }

    private func approveChapterMilestone(_ request: ApprovalRequest) throws {
        guard let value = request.payload, let chapterID = UUID(uuidString: value) else { throw AgentControllerError.invalidApprovalPayload }
        let result = session.approveChapter(chapterID: chapterID)
        guard result?.passed == true else { throw AgentControllerError.qualityGateFailed(result?.blockingIssues.count ?? 0) }
        session.resolveApproval(id: request.id, status: .approved)
        guard var run = request.relatedRunID.flatMap({ id in session.workspace.agentSession.runs.first { $0.id == id } }) else { return }
        let index = run.currentStepIndex
        if index < run.steps.count {
            run.steps[index].status = .completed
            run.steps[index].completedAt = Date()
            run.currentStepIndex += 1
        }
        run.status = .running
        run.updatedAt = Date()
        session.upsertAgentRun(run)
        resumeRun()
    }

    private func blockActiveRun(message: String) {
        if var run = activeRun {
            run.status = .waitingForApproval
            run.errorMessage = message
            run.updatedAt = Date()
            if run.currentStepIndex < run.steps.count {
                run.steps[run.currentStepIndex].status = .blocked
                run.steps[run.currentStepIndex].detail = message
            }
            session.upsertAgentRun(run)
            let request = ApprovalRequest(kind: .blocker, title: "Agent 需要你的决定", summary: message, relatedRunID: run.id)
            session.addApprovalRequest(request)
            session.appendAgentMessage(AgentMessage(role: .assistant, kind: .approval, content: message, relatedRunID: run.id, relatedApprovalID: request.id))
        }
        state = .waiting(message)
    }

    private func markRelatedRunPaused(_ request: ApprovalRequest) {
        guard let runID = request.relatedRunID,
              var run = session.workspace.agentSession.runs.first(where: { $0.id == runID }) else {
            state = .idle
            return
        }
        run.status = .paused
        run.updatedAt = Date()
        if run.currentStepIndex < run.steps.count, run.steps[run.currentStepIndex].status == .blocked {
            run.steps[run.currentStepIndex].status = .pending
            run.steps[run.currentStepIndex].detail = "等待用户修改后恢复"
        }
        session.upsertAgentRun(run)
        state = .paused
    }

    private func resumeRelatedRun(_ request: ApprovalRequest) {
        guard let runID = request.relatedRunID,
              var run = session.workspace.agentSession.runs.first(where: { $0.id == runID }) else {
            state = .idle
            return
        }
        run.status = .paused
        run.updatedAt = Date()
        if run.currentStepIndex < run.steps.count, run.steps[run.currentStepIndex].status == .blocked {
            run.steps[run.currentStepIndex].status = .pending
            run.steps[run.currentStepIndex].detail = ""
        }
        session.upsertAgentRun(run)
        resumeRun()
    }

    private func rewindRelatedRunForReview(_ request: ApprovalRequest) {
        guard let runID = request.relatedRunID,
              var run = session.workspace.agentSession.runs.first(where: { $0.id == runID }),
              let chapterID = request.payload.flatMap({ UUID(uuidString: $0) }) else {
            markRelatedRunPaused(request)
            return
        }
        if let reviewIndex = run.steps.lastIndex(where: { $0.chapterID == chapterID && $0.tool == .runReviews }) {
            for index in reviewIndex..<run.steps.count where run.steps[index].chapterID == chapterID {
                run.steps[index].status = .pending
                run.steps[index].detail = "章节被要求修改，需重新审稿"
                if run.steps[index].tool == .rewriteIssues { run.steps[index].attempt = 0 }
            }
            run.currentStepIndex = reviewIndex
        }
        run.status = .paused
        run.updatedAt = Date()
        session.upsertAgentRun(run)
        state = .paused
    }

    private func cancelRelatedRun(_ request: ApprovalRequest) {
        guard let runID = request.relatedRunID,
              var run = session.workspace.agentSession.runs.first(where: { $0.id == runID }) else {
            state = .idle
            return
        }
        run.status = .cancelled
        run.updatedAt = Date()
        session.upsertAgentRun(run)
        state = .idle
    }

    private func seedConversationIfNeeded() {
        guard messages.isEmpty else { return }
        let project = session.workspace.project
        let content: String
        if project.genre == "待确认" || project.sellingPoint.isEmpty {
            content = "我们从想法开始。你想写什么类型的故事？可以只说一个模糊念头，我会逐步帮你整理成设定。"
        } else {
            content = "我已读取《\(project.title)》。你可以继续聊设定、让我规划下一章，或选择一个执行范围开始生成。"
        }
        session.appendAgentMessage(AgentMessage(role: .assistant, content: content))
    }

    private func restoreInterruptedRun() {
        guard var run = activeRun else { return }
        if run.status == .running || run.status == .queued {
            run.status = .paused
            if run.currentStepIndex < run.steps.count, run.steps[run.currentStepIndex].status == .running {
                run.steps[run.currentStepIndex].status = .pending
                run.steps[run.currentStepIndex].detail = "上次运行被系统中断，可从此步骤恢复"
            }
            session.upsertAgentRun(run)
            state = .paused
        } else if run.status == .paused {
            state = .paused
        } else if run.status == .waitingForApproval {
            state = .waiting("等待处理确认请求")
        }
    }

    private func appendAutomaticHealthSummary() async {
        let report = await HealthCheckRunner().run(session: session, settings: session.settings)
        let failed = report.checks.filter { $0.status == .failed }.count
        let warnings = report.checks.filter { $0.status == .warning }.count
        session.appendAgentMessage(AgentMessage(
            role: .tool,
            kind: .report,
            content: "已自动运行脱敏自检：\(failed) 项失败，\(warnings) 项需注意。可从 Agent 工具菜单导出完整报告。"
        ))
    }
}

private enum AgentControllerError: LocalizedError {
    case invalidApprovalPayload
    case staleProposal
    case noChapter
    case noCandidate
    case insufficientChapters(requested: Int, available: Int)
    case revisionLimitReached(Int)
    case qualityGateFailed(Int)
    case callBudgetReached
    case toolNotRunnable(String)

    var errorDescription: String? {
        switch self {
        case .invalidApprovalPayload: return "确认请求的数据格式无效。"
        case .staleProposal: return "工程已发生变化，请让 Agent 重新生成方案。"
        case .noChapter: return "执行范围内没有可用章节。"
        case .noCandidate: return "没有找到可采用的正文候选。"
        case .insufficientChapters(let requested, let available): return "执行范围需要 \(requested) 个已有章卡，当前只有 \(available) 个。请先让 Agent 规划更多章节。"
        case .revisionLimitReached(let count): return "自动修订两轮后仍有 \(count) 个高等级问题，已暂停等待决定。"
        case .qualityGateFailed(let count): return "质量门禁未通过，仍有 \(count) 个阻断问题；Pass 不会绕过门禁。"
        case .callBudgetReached: return "已达到本次任务的模型调用上限。"
        case .toolNotRunnable(let tool): return "工具 \(tool) 不能在自动执行任务中运行。"
        }
    }
}

private extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
