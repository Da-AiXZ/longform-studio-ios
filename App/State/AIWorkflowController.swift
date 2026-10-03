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

    let executor: WorkflowToolExecutor
    private var task: Task<Void, Never>?
    private var operationID: UUID?

    init(executor: WorkflowToolExecutor) {
        self.executor = executor
    }

    func cancel() {
        guard task != nil else { return }
        task?.cancel()
        state = .cancelled
    }

    func cancelAndWait() async {
        let currentTask = task
        cancel()
        await currentTask?.value
    }

    func generateCreativeOptions(session: ProjectSession) {
        run(label: "生成创意方案") { [weak self, weak session] in
            guard let self, let session else { return }
            let result = try await self.executor.completePlanning(
                task: .creativeOptions,
                instruction: "基于作品信息提出三个明显不同、可支撑长篇连载的创意方案。每个方案包含：一句话卖点、主角起点、核心机制、前30章主线、长期升级空间、主要风险。方案之间不能只换名字。",
                session: session
            )
            self.storePlanning(result)
            self.state = .completed("已生成 3 个创意方案，请人工选择并整理进故事圣经。")
        }
    }

    func generateStoryBibleCandidate(session: ProjectSession) {
        run(label: "生成故事圣经候选") { [weak self, weak session] in
            guard let self, let session else { return }
            let result = try await self.executor.completePlanning(
                task: .storyBible,
                instruction: "生成一份可供人工确认的故事圣经，包含：核心前提、主题、中央冲突、终局承诺、主角弧线、力量体系硬规则、长线悬念、文风边界和禁止使用的廉价解法。不要把候选内容当成已经批准的正式事实。",
                session: session
            )
            self.storePlanning(result)
            self.state = .completed("故事圣经候选已生成，确认后再写入规划。")
        }
    }

    func generateVolumeOutline(session: ProjectSession) {
        run(label: "生成卷纲候选") { [weak self, weak session] in
            guard let self, let session else { return }
            let result = try await self.executor.completePlanning(
                task: .volumeOutline,
                instruction: "基于已批准故事圣经生成下一卷卷纲。说明本卷目标、主要对手、阶段性升级、每个转折的因果链、高潮、追读节点、卷末兑现与下一卷悬念。只输出候选，不擅自新增正式世界规则。",
                session: session
            )
            self.storePlanning(result)
            self.state = .completed("卷纲候选已生成，请人工确认。")
        }
    }

    func generateChapterOutlineOptions(session: ProjectSession, chapter: ChapterCard) {
        run(label: "生成章纲方案") { [weak self, weak session] in
            guard let self, let session else { return }
            let result = try await self.executor.completePlanning(
                task: .chapterOutline,
                instruction: "为第\(chapter.number)章《\(chapter.title)》提出两个结构明显不同的章纲方案。每个方案包含：章节目标、冲突升级、三个场景、信息释放、转折、兑现和结尾钩子，并说明与前章及长线目标的连接。",
                chapter: chapter,
                session: session
            )
            self.storePlanning(result)
            self.state = .completed("已生成两个章纲方案，请选择后填写章卡。")
        }
    }

    func generateDraft(session: ProjectSession, chapter: ChapterCard) {
        run(label: "生成章节候选") { [weak self, weak session] in
            guard let self, let session else { return }
            let result = try await self.executor.generateDraft(session: session, chapter: chapter) { text, reason in
                self.streamedText = text
                self.finishReason = reason
                if reason == "length" { self.state = .running("正文达到输出上限，补写结尾") }
            }
            self.streamedText = result.text
            self.finishReason = result.finishReason
            self.state = .completed("候选正文已保存，当前正文未被覆盖。")
        }
    }

    func runFourReviews(session: ProjectSession, chapter: ChapterCard) {
        run(label: "运行四类审稿") { [weak self, weak session] in
            guard let self, let session else { return }
            _ = try await self.executor.runReviews(session: session, chapter: chapter)
            self.state = .completed("四类审稿已完成。")
        }
    }

    func rewrite(session: ProjectSession, chapter: ChapterCard, issueIDs: Set<UUID>) {
        run(label: "定向重写") { [weak self, weak session] in
            guard let self, let session else { return }
            let result = try await self.executor.rewrite(session: session, chapter: chapter, issueIDs: issueIDs)
            self.planningResult = result.body
            self.state = .completed("修订候选已保存，当前正文未被覆盖。")
        }
    }

    func rewriteSelection(session: ProjectSession, chapter: ChapterCard, range: NSRange, instruction: String) {
        run(label: "改写选中段落") { [weak self, weak session] in
            guard let self, let session else { return }
            _ = try await self.executor.rewriteSelection(session: session, chapter: chapter, range: range, instruction: instruction)
            self.state = .completed("选段改写候选已保存，当前正文未被覆盖。")
        }
    }

    func extractCandidateFacts(session: ProjectSession, chapter: ChapterCard) {
        run(label: "提取连续性事实") { [weak self, weak session] in
            guard let self, let session else { return }
            let facts = try await self.executor.extractFacts(session: session, chapter: chapter)
            self.state = .completed("提取了 \(facts.count) 条候选事实；只有章节批准后才会入正式台账。")
        }
    }

    func runRegressionReview(session: ProjectSession) {
        run(label: "跨章回归审稿") { [weak self, weak session] in
            guard let self, let session else { return }
            _ = try await self.executor.runRegressionReview(session: session)
            self.state = .completed("最近已批准章节的回归审稿已完成。")
        }
    }

    private func storePlanning(_ result: WorkflowToolExecutor.PlanningResult) {
        planningResult = result.text
        latestPlanningArtifactID = result.artifactID
    }

    private func run(label: String, operation: @escaping @MainActor () async throws -> Void) {
        task?.cancel()
        let currentOperationID = UUID()
        operationID = currentOperationID
        streamedText = ""
        finishReason = nil
        state = .running(label)
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.operationID == currentOperationID {
                    self.task = nil
                    self.operationID = nil
                }
            }
            do {
                try await operation()
                guard self.operationID == currentOperationID else { return }
                if case .running = self.state { self.state = .completed("已完成") }
            } catch is CancellationError {
                if self.operationID == currentOperationID { self.state = .cancelled }
            } catch {
                guard self.operationID == currentOperationID else { return }
                self.state = .failed(error.localizedDescription)
                await DiagnosticLogger.shared.log(category: "Workflow", message: error.localizedDescription)
            }
        }
    }
}
