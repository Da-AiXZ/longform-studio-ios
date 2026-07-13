import Foundation
import Combine
import NovelCore

@MainActor
final class ProjectSession: ObservableObject, Identifiable {
    let id: UUID
    @Published private(set) var workspace: ProjectWorkspace
    @Published private(set) var isSaving = false
    @Published private(set) var lastSavedAt: Date?
    @Published var errorMessage: String?
    @Published var selectedChapterID: UUID?
    @Published private(set) var loadingVersionIDs = Set<UUID>()

    let repository: ProjectRepository
    let settings: SettingsStore
    let aiClient: AIChatClient
    private var saveTask: Task<Void, Never>?

    init(workspace: ProjectWorkspace, repository: ProjectRepository, settings: SettingsStore, aiClient: AIChatClient = OpenAICompatibleClient()) {
        self.id = workspace.project.id
        self.workspace = workspace
        self.repository = repository
        self.settings = settings
        self.aiClient = aiClient
        self.selectedChapterID = workspace.chapters.sorted { $0.number < $1.number }.first?.id
    }

    var sortedChapters: [ChapterCard] { workspace.chapters.sorted { $0.number < $1.number } }
    var selectedChapter: ChapterCard? {
        guard let selectedChapterID else { return sortedChapters.first }
        return workspace.chapters.first { $0.id == selectedChapterID }
    }

    func activeVersion(for chapter: ChapterCard) -> ChapterVersion? { workspace.activeVersion(for: chapter) }

    func isActiveBodyLoaded(for chapter: ChapterCard) -> Bool {
        activeVersion(for: chapter)?.isBodyLoaded == true
    }

    func body(for chapter: ChapterCard) async throws -> String {
        guard let versionID = chapter.activeVersionID,
              let index = workspace.versions.firstIndex(where: { $0.id == versionID }) else { return "" }
        if workspace.versions[index].isBodyLoaded { return workspace.versions[index].body }
        let body = try await repository.loadVersionBody(projectID: workspace.project.id, versionID: versionID)
        if let currentIndex = workspace.versions.firstIndex(where: { $0.id == versionID }) {
            workspace.versions[currentIndex].body = body
            workspace.versions[currentIndex].isBodyLoaded = true
        }
        return body
    }

    func body(forVersionID versionID: UUID) async throws -> String {
        guard let version = workspace.versions.first(where: { $0.id == versionID }) else { return "" }
        if version.isBodyLoaded { return version.body }
        let body = try await repository.loadVersionBody(projectID: workspace.project.id, versionID: versionID)
        if let index = workspace.versions.firstIndex(where: { $0.id == versionID }) {
            workspace.versions[index].body = body
            workspace.versions[index].isBodyLoaded = true
        }
        return body
    }

    func searchHistoricalPassages(before chapter: ChapterCard, query: String, limit: Int = 12) async throws -> [ContextItem] {
        let priorVersionIDs = sortedChapters
            .filter { $0.number < chapter.number && $0.status == .approved }
            .compactMap(\.activeVersionID)
        return try await repository.searchPassages(projectID: workspace.project.id, versionIDs: priorVersionIDs, query: query, limit: limit)
    }

    func loadActiveBody(for chapter: ChapterCard) async {
        guard let versionID = chapter.activeVersionID else { return }
        await loadVersionBody(versionID)
    }

    func loadVersions(for chapter: ChapterCard) async {
        for versionID in chapter.versionIDs { await loadVersionBody(versionID) }
    }

    private func loadVersionBody(_ versionID: UUID) async {
        guard let index = workspace.versions.firstIndex(where: { $0.id == versionID }), !workspace.versions[index].isBodyLoaded else { return }
        loadingVersionIDs.insert(versionID)
        defer { loadingVersionIDs.remove(versionID) }
        do {
            workspace.versions[index].body = try await repository.loadVersionBody(projectID: workspace.project.id, versionID: versionID)
            workspace.versions[index].isBodyLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func versions(for chapter: ChapterCard) -> [ChapterVersion] {
        workspace.versions.filter { $0.chapterID == chapter.id }.sorted { $0.createdAt > $1.createdAt }
    }

    func candidateVersions(for chapter: ChapterCard) -> [ChapterVersion] {
        versions(for: chapter).filter { $0.id != chapter.activeVersionID && $0.approvedAt == nil }
    }

    func reviews(for chapter: ChapterCard) -> [ReviewReport] {
        workspace.reviews.filter { $0.chapterID == chapter.id && $0.chapterVersionID == chapter.activeVersionID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func unresolvedIssues(for chapter: ChapterCard) -> [ReviewIssue] {
        reviews(for: chapter).flatMap(\.issues).filter { !$0.resolved }
    }

    func updateProject(_ update: (inout NovelProject) -> Void) {
        update(&workspace.project)
        workspace.project.planRevision += 1
        workspace.project.updatedAt = Date()
        scheduleSave()
    }

    func setWorkspaceMode(_ mode: WorkspaceMode) {
        workspace.preferredMode = mode
        scheduleSave(immediate: true)
    }

    func setAgentPolicy(_ policy: AgentPolicy) {
        workspace.agentSession.policy = policy
        workspace.agentSession.updatedAt = Date()
        scheduleSave(immediate: true)
    }

    func appendAgentMessage(_ message: AgentMessage) {
        workspace.agentSession.messages.append(message)
        workspace.agentSession.updatedAt = Date()
        scheduleSave(immediate: true)
    }

    func addApprovalRequest(_ request: ApprovalRequest) {
        workspace.agentSession.approvals.append(request)
        workspace.agentSession.updatedAt = Date()
        scheduleSave(immediate: true)
    }

    func resolveApproval(id: UUID, status: ApprovalStatus) {
        guard let index = workspace.agentSession.approvals.firstIndex(where: { $0.id == id }) else { return }
        workspace.agentSession.approvals[index].status = status
        workspace.agentSession.approvals[index].resolvedAt = Date()
        workspace.agentSession.updatedAt = Date()
        scheduleSave(immediate: true)
    }

    func upsertAgentRun(_ run: AgentRun) {
        if let index = workspace.agentSession.runs.firstIndex(where: { $0.id == run.id }) {
            workspace.agentSession.runs[index] = run
        } else {
            workspace.agentSession.runs.append(run)
        }
        workspace.agentSession.activeRunID = run.status == .running || run.status == .queued || run.status == .paused || run.status == .waitingForApproval ? run.id : nil
        workspace.agentSession.updatedAt = Date()
        scheduleSave(immediate: true)
    }

    func applyPlanningPatch(_ patch: ProjectPlanPatch) throws {
        guard patch.baseRevision == workspace.project.planRevision else {
            throw ProjectSessionError.stalePlanningPatch(expected: workspace.project.planRevision, received: patch.baseRevision)
        }
        let selectedTemplate: WritingTemplate?
        if patch.clearAppliedTemplate == true {
            selectedTemplate = nil
        } else if let templateID = patch.selectedTemplateID {
            guard let template = settings.writingTemplates.first(where: { $0.id == templateID }) else {
                throw ProjectSessionError.missingTemplate
            }
            selectedTemplate = template
        } else {
            selectedTemplate = workspace.appliedTemplate?.template
        }
        if let value = patch.title, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { workspace.project.title = value }
        if let value = patch.platform { workspace.project.platform = value }
        if let value = patch.genre, !value.isEmpty { workspace.project.genre = value }
        if let value = patch.sellingPoint { workspace.project.sellingPoint = value }
        if let value = patch.targetWordCount { workspace.project.targetWordCount = min(5_000_000, max(50_000, value)) }
        if let value = patch.protagonistGoal { workspace.project.protagonistGoal = value }
        if let value = patch.restrictedContent { workspace.project.restrictedContent = value }
        if let value = patch.perspective { workspace.project.perspective = value }
        if let value = patch.targetChapterWords { workspace.project.targetChapterWords = min(8_000, max(1_000, value)) }
        if let value = patch.bible { workspace.bible = value }
        if let value = patch.characters { mergeCharacters(value) }
        if let value = patch.worldRules { mergeWorldRules(value) }
        if let value = patch.volumes { mergeVolumes(value) }
        if let value = patch.chapters {
            mergePlannedChapters(value)
        }
        if patch.clearAppliedTemplate == true {
            workspace.appliedTemplate = nil
        } else if patch.selectedTemplateID != nil, let template = selectedTemplate {
            workspace.appliedTemplate = WritingTemplateSnapshot(sourceTemplateID: template.id, template: template)
        }
        workspace.project.planRevision += 1
        workspace.project.schemaVersion = ProjectRepository.currentSchemaVersion
        workspace.project.updatedAt = Date()
        scheduleSave(immediate: true)
    }

    func applyTemplate(_ template: WritingTemplate?) {
        workspace.appliedTemplate = template.map { WritingTemplateSnapshot(sourceTemplateID: $0.id, template: $0) }
        scheduleSave(immediate: true)
    }

    func updateBible(_ bible: StoryBible) {
        workspace.bible = bible
        workspace.project.planRevision += 1
        scheduleSave()
    }

    func addVolume(_ volume: VolumeOutline) {
        workspace.volumes.append(volume)
        workspace.project.planRevision += 1
        scheduleSave()
    }

    func updateVolume(_ volume: VolumeOutline) {
        if let index = workspace.volumes.firstIndex(where: { $0.id == volume.id }) {
            workspace.volumes[index] = volume
        } else {
            workspace.volumes.append(volume)
        }
        workspace.project.planRevision += 1
        scheduleSave()
    }

    func addCharacter(_ character: NovelCore.Character) {
        workspace.characters.append(character)
        workspace.project.planRevision += 1
        scheduleSave()
    }

    func updateCharacter(_ character: NovelCore.Character) {
        if let index = workspace.characters.firstIndex(where: { $0.id == character.id }) {
            workspace.characters[index] = character
        } else {
            workspace.characters.append(character)
        }
        workspace.project.planRevision += 1
        scheduleSave()
    }

    func addWorldRule(_ rule: WorldRule) {
        workspace.worldRules.append(rule)
        workspace.project.planRevision += 1
        scheduleSave()
    }

    func updateWorldRule(_ rule: WorldRule) {
        if let index = workspace.worldRules.firstIndex(where: { $0.id == rule.id }) {
            workspace.worldRules[index] = rule
        } else {
            workspace.worldRules.append(rule)
        }
        workspace.project.planRevision += 1
        scheduleSave()
    }

    func addTimelineEvent(_ event: TimelineEvent) {
        workspace.timeline.append(event)
        workspace.timeline.sort { $0.order < $1.order }
        scheduleSave()
    }

    func addForeshadowing(_ item: Foreshadowing) {
        workspace.foreshadowing.append(item)
        scheduleSave()
    }

    func updateStyleProfile(_ profile: StyleProfile) {
        workspace.styleProfile = profile
        scheduleSave(immediate: true)
    }

    func resolveIssue(reportID: UUID, issueID: UUID, resolved: Bool) {
        guard let reportIndex = workspace.reviews.firstIndex(where: { $0.id == reportID }),
              let issueIndex = workspace.reviews[reportIndex].issues.firstIndex(where: { $0.id == issueID }) else { return }
        workspace.reviews[reportIndex].issues[issueIndex].resolved = resolved
        scheduleSave()
    }

    func addChapter(title: String = "") {
        let number = (workspace.chapters.map(\.number).max() ?? 0) + 1
        var chapter = ChapterCard(number: number, title: title.isEmpty ? "第\(number)章" : title, status: .drafting)
        let version = ChapterVersion(chapterID: chapter.id, source: .manual, body: "")
        chapter.activeVersionID = version.id
        chapter.versionIDs = [version.id]
        workspace.chapters.append(chapter)
        workspace.versions.append(version)
        workspace.project.planRevision += 1
        selectedChapterID = chapter.id
        scheduleSave()
    }

    func updateChapterCard(id: UUID, _ update: (inout ChapterCard) -> Void) {
        guard let index = workspace.chapters.firstIndex(where: { $0.id == id }) else { return }
        update(&workspace.chapters[index])
        workspace.chapters[index].updatedAt = Date()
        workspace.project.planRevision += 1
        scheduleSave()
    }

    func updateActiveBody(chapterID: UUID, body: String) {
        guard let chapterIndex = workspace.chapters.firstIndex(where: { $0.id == chapterID }) else { return }
        let activeID = ensureEditableVersion(chapterIndex: chapterIndex)
        _ = updateBody(chapterID: chapterID, versionID: activeID, body: body)
    }

    @discardableResult
    func updateBody(chapterID: UUID, versionID: UUID, body: String) -> UUID? {
        guard let chapterIndex = workspace.chapters.firstIndex(where: { $0.id == chapterID }),
              let versionIndex = workspace.versions.firstIndex(where: { $0.id == versionID }) else { return nil }
        let oldBody = workspace.versions[versionIndex].body
        guard oldBody != body else { return versionID }
        let hasBoundReviews = workspace.reviews.contains { $0.chapterVersionID == versionID }
        if workspace.versions[versionIndex].approvedAt != nil || hasBoundReviews {
            let version = ChapterVersion(
                chapterID: chapterID,
                source: .manual,
                body: body,
                manualEditCharacters: editDistanceEstimate(oldBody, body),
                note: workspace.versions[versionIndex].approvedAt != nil ? "从已批准版本继续编辑" : "正文修改后使旧审稿失效"
            )
            workspace.versions.append(version)
            workspace.chapters[chapterIndex].versionIDs.append(version.id)
            workspace.chapters[chapterIndex].activeVersionID = version.id
            workspace.chapters[chapterIndex].status = .drafting
            workspace.chapters[chapterIndex].updatedAt = Date()
            scheduleSave()
            return version.id
        }
        workspace.versions[versionIndex].manualEditCharacters += editDistanceEstimate(oldBody, body)
        workspace.versions[versionIndex].body = body
        workspace.versions[versionIndex].isBodyLoaded = true
        workspace.versions[versionIndex].characterCount = TextAnalyzer.statistics(for: body).chineseCharacterCount
        if workspace.chapters[chapterIndex].activeVersionID == versionID {
            workspace.chapters[chapterIndex].status = .drafting
            workspace.chapters[chapterIndex].updatedAt = Date()
        }
        scheduleSave()
        return versionID
    }

    @discardableResult
    func addCandidateVersion(chapterID: UUID, body: String, source: VersionSource, profileID: UUID?, generationRecordID: UUID?, note: String = "") -> ChapterVersion {
        let version = ChapterVersion(chapterID: chapterID, source: source, body: body, modelProfileID: profileID, generationRecordID: generationRecordID, note: note)
        workspace.versions.append(version)
        if let index = workspace.chapters.firstIndex(where: { $0.id == chapterID }) {
            workspace.chapters[index].versionIDs.append(version.id)
            workspace.chapters[index].status = .reviewing
            workspace.chapters[index].updatedAt = Date()
        }
        scheduleSave()
        return version
    }

    func acceptVersion(chapterID: UUID, versionID: UUID) {
        guard workspace.versions.contains(where: { $0.id == versionID }),
              let index = workspace.chapters.firstIndex(where: { $0.id == chapterID }) else { return }
        workspace.chapters[index].activeVersionID = versionID
        workspace.chapters[index].status = .reviewing
        workspace.chapters[index].updatedAt = Date()
        if let generationID = workspace.versions.first(where: { $0.id == versionID })?.generationRecordID,
           let recordIndex = workspace.generationRecords.firstIndex(where: { $0.id == generationID }) {
            workspace.generationRecords[recordIndex].selectedByUser = true
        }
        scheduleSave(immediate: true)
    }

    func addReview(_ report: ReviewReport) {
        workspace.reviews.append(report)
        scheduleSave(immediate: true)
    }

    func addGenerationRecord(_ record: GenerationRecord) {
        workspace.generationRecords.append(record)
        scheduleSave(immediate: true)
    }

    func addPlanningArtifact(_ artifact: PlanningArtifact) {
        workspace.planningArtifacts.append(artifact)
        scheduleSave(immediate: true)
    }

    func selectPlanningArtifact(id: UUID) {
        guard let index = workspace.planningArtifacts.firstIndex(where: { $0.id == id }) else { return }
        workspace.planningArtifacts[index].selectedAt = Date()
        if let recordIndex = workspace.generationRecords.firstIndex(where: { $0.id == workspace.planningArtifacts[index].generationRecordID }) {
            workspace.generationRecords[recordIndex].selectedByUser = true
        }
        scheduleSave(immediate: true)
    }

    func addCandidateFacts(_ facts: [ContinuityFact]) {
        let accepted = workspace.facts.filter { $0.status == .accepted }
        var existingKeys = Set(workspace.facts.map { "\($0.chapterID)|\($0.subject)|\($0.predicate)|\($0.value)" })
        var additions: [ContinuityFact] = []
        for var fact in facts {
            let key = "\(fact.chapterID)|\(fact.subject)|\(fact.predicate)|\(fact.value)"
            guard !existingKeys.contains(key) else { continue }
            existingKeys.insert(key)
            if fact.conflictWithFactID == nil {
                fact.conflictWithFactID = accepted.first {
                    $0.subject == fact.subject && $0.predicate == fact.predicate && $0.value != fact.value
                }?.id
            }
            additions.append(fact)
        }
        workspace.facts.append(contentsOf: additions)
        scheduleSave()
    }

    func rejectConflictingCandidateFacts(chapterID: UUID) {
        for index in workspace.facts.indices where
            workspace.facts[index].chapterID == chapterID &&
            workspace.facts[index].status == .candidate &&
            workspace.facts[index].conflictWithFactID != nil {
            workspace.facts[index].status = .rejected
        }
        scheduleSave(immediate: true)
    }

    func approveChapter(chapterID: UUID, manualOverrideReason: String? = nil) -> QualityGateResult? {
        guard let chapterIndex = workspace.chapters.firstIndex(where: { $0.id == chapterID }),
              let activeID = workspace.chapters[chapterIndex].activeVersionID,
              let versionIndex = workspace.versions.firstIndex(where: { $0.id == activeID }) else { return nil }
        let chapter = workspace.chapters[chapterIndex]
        guard workspace.versions[versionIndex].isBodyLoaded,
              !workspace.versions[versionIndex].body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return qualityGateResult(for: chapter)
        }
        let result = qualityGateResult(for: chapter, manualOverrideReason: manualOverrideReason)
        guard result.passed else { return result }
        workspace.versions[versionIndex].approvedAt = Date()
        if let reason = result.overrideReason {
            let prefix = workspace.versions[versionIndex].note.isEmpty ? "" : workspace.versions[versionIndex].note + "\n"
            workspace.versions[versionIndex].note = prefix + "人工覆盖理由：" + reason
        }
        workspace.chapters[chapterIndex].status = .approved
        for index in workspace.facts.indices where workspace.facts[index].chapterID == chapterID && workspace.facts[index].status == .candidate {
            workspace.facts[index].status = workspace.facts[index].conflictWithFactID == nil ? .accepted : .rejected
        }
        scheduleSave(immediate: true)
        return result
    }

    func qualityGateResult(for chapter: ChapterCard, manualOverrideReason: String? = nil) -> QualityGateResult {
        let body = activeVersion(for: chapter).flatMap { $0.isBodyLoaded ? $0.body : nil } ?? ""
        var local = LocalQualityScanner().scan(text: body, targetWords: workspace.project.targetChapterWords, bannedTerms: workspace.project.restrictedContent)
        let reports = reviews(for: chapter)
        let requiredKinds: Set<ReviewKind> = [.plot, .continuity, .prose, .platform]
        let missingKinds = requiredKinds.subtracting(Set(reports.map(\.kind)))
        if !missingKinds.isEmpty {
            local.append(ReviewIssue(
                severity: .high,
                dimension: .continuity,
                title: "四类审稿尚未完成",
                evidence: "缺少：\(missingKinds.map(\.displayName).sorted().joined(separator: "、"))",
                suggestion: "运行情节、连续性、文字和平台四类独立审稿。"
            ))
        }
        return QualityGate.evaluate(
            reports: reports,
            localIssues: local,
            profile: settings.platformProfile(for: workspace.project.platform),
            manualOverrideReason: manualOverrideReason
        )
    }

    func localIssues(for chapter: ChapterCard) -> [ReviewIssue] {
        guard let version = activeVersion(for: chapter), version.isBodyLoaded else { return [] }
        return LocalQualityScanner().scan(text: version.body, targetWords: workspace.project.targetChapterWords, bannedTerms: workspace.project.restrictedContent)
    }

    func exportArchiveURL() async throws -> URL {
        await flushSave()
        let data = try await repository.exportArchive(workspace)
        let safeName = workspace.project.title.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName).novelproj")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    func exportManuscriptURL(markdown: Bool, chapterID: UUID? = nil) async throws -> URL {
        let ext = markdown ? "md" : "txt"
        let suffix = chapterID.flatMap { id in workspace.chapters.first(where: { $0.id == id })?.title }.map { "-\($0)" } ?? ""
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(workspace.project.title)\(suffix).\(ext)")
        try await repository.exportManuscript(workspace, markdown: markdown, selectedChapterID: chapterID, to: url)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        return url
    }

    func flushSave() async {
        saveTask?.cancel()
        await saveNow()
    }

    private func ensureEditableVersion(chapterIndex: Int) -> UUID {
        if let activeID = workspace.chapters[chapterIndex].activeVersionID,
           let index = workspace.versions.firstIndex(where: { $0.id == activeID }),
           workspace.versions[index].approvedAt == nil {
            return activeID
        }
        let oldBody = workspace.chapters[chapterIndex].activeVersionID.flatMap { id in workspace.versions.first(where: { $0.id == id })?.body } ?? ""
        let version = ChapterVersion(chapterID: workspace.chapters[chapterIndex].id, source: .manual, body: oldBody, note: "从已批准版本继续编辑")
        workspace.versions.append(version)
        workspace.chapters[chapterIndex].activeVersionID = version.id
        workspace.chapters[chapterIndex].versionIDs.append(version.id)
        return version.id
    }

    private func mergePlannedChapters(_ chapters: [ChapterCard]) {
        for incoming in chapters.sorted(by: { $0.number < $1.number }) {
            if let index = workspace.chapters.firstIndex(where: { $0.id == incoming.id || $0.number == incoming.number }) {
                let existing = workspace.chapters[index]
                var merged = existing
                merged.volumeID = incoming.volumeID ?? existing.volumeID
                if !incoming.title.isEmpty { merged.title = incoming.title }
                if !incoming.goal.isEmpty { merged.goal = incoming.goal }
                if !incoming.conflict.isEmpty { merged.conflict = incoming.conflict }
                if !incoming.turn.isEmpty { merged.turn = incoming.turn }
                if !incoming.hook.isEmpty { merged.hook = incoming.hook }
                if !incoming.summary.isEmpty { merged.summary = incoming.summary }
                if !incoming.linkedEntityIDs.isEmpty { merged.linkedEntityIDs = incoming.linkedEntityIDs }
                merged.updatedAt = Date()
                workspace.chapters[index] = merged
            } else {
                var chapter = incoming
                chapter.status = .planned
                chapter.activeVersionID = nil
                chapter.versionIDs = []
                workspace.chapters.append(chapter)
            }
        }
        workspace.chapters.sort { $0.number < $1.number }
        if selectedChapterID == nil { selectedChapterID = workspace.chapters.first?.id }
    }

    private func mergeCharacters(_ characters: [NovelCore.Character]) {
        for incoming in characters where !incoming.name.isEmpty {
            if let index = workspace.characters.firstIndex(where: { $0.id == incoming.id || $0.name == incoming.name }) {
                var merged = workspace.characters[index]
                if !incoming.name.isEmpty { merged.name = incoming.name }
                if !incoming.role.isEmpty { merged.role = incoming.role }
                if !incoming.desire.isEmpty { merged.desire = incoming.desire }
                if !incoming.fear.isEmpty { merged.fear = incoming.fear }
                if !incoming.flaw.isEmpty { merged.flaw = incoming.flaw }
                if !incoming.arc.isEmpty { merged.arc = incoming.arc }
                if !incoming.voice.isEmpty { merged.voice = incoming.voice }
                if !incoming.currentState.isEmpty { merged.currentState = incoming.currentState }
                workspace.characters[index] = merged
            } else {
                workspace.characters.append(incoming)
            }
        }
    }

    private func mergeWorldRules(_ rules: [WorldRule]) {
        for incoming in rules where !incoming.title.isEmpty {
            if let index = workspace.worldRules.firstIndex(where: { $0.id == incoming.id || $0.title == incoming.title }) {
                var merged = workspace.worldRules[index]
                if !incoming.category.isEmpty { merged.category = incoming.category }
                if !incoming.title.isEmpty { merged.title = incoming.title }
                if !incoming.detail.isEmpty { merged.detail = incoming.detail }
                merged.immutable = incoming.immutable
                workspace.worldRules[index] = merged
            } else {
                workspace.worldRules.append(incoming)
            }
        }
    }

    private func mergeVolumes(_ volumes: [VolumeOutline]) {
        for incoming in volumes {
            if let index = workspace.volumes.firstIndex(where: { $0.id == incoming.id || $0.number == incoming.number }) {
                var merged = workspace.volumes[index]
                if !incoming.title.isEmpty { merged.title = incoming.title }
                if !incoming.goal.isEmpty { merged.goal = incoming.goal }
                if !incoming.climax.isEmpty { merged.climax = incoming.climax }
                if !incoming.resolution.isEmpty { merged.resolution = incoming.resolution }
                workspace.volumes[index] = merged
            } else {
                workspace.volumes.append(incoming)
            }
        }
        workspace.volumes.sort { $0.number < $1.number }
    }

    private func editDistanceEstimate(_ old: String, _ new: String) -> Int {
        let sharedPrefix = zip(old, new).prefix { $0.0 == $0.1 }.count
        return max(old.count, new.count) - sharedPrefix
    }

    private func scheduleSave(immediate: Bool = false) {
        workspace.project.updatedAt = Date()
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            if !immediate { try? await Task.sleep(nanoseconds: 700_000_000) }
            guard !Task.isCancelled else { return }
            await self?.saveNow()
        }
    }

    private func saveNow() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await repository.save(workspace)
            lastSavedAt = Date()
            errorMessage = nil
            applyFileProtection()
        } catch {
            errorMessage = error.localizedDescription
            await DiagnosticLogger.shared.log(category: "Storage", message: error.localizedDescription)
        }
    }

    private func applyFileProtection() {
        let directory = repository.projectDirectory(workspace.project.id)
        let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        try? FileManager.default.setAttributes(attributes, ofItemAtPath: directory.path)
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in enumerator {
            try? FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
        }
    }
}

private enum ProjectSessionError: LocalizedError {
    case stalePlanningPatch(expected: Int, received: Int)
    case missingTemplate

    var errorDescription: String? {
        switch self {
        case .stalePlanningPatch(let expected, let received):
            return "规划方案基于 revision \(received)，当前工程已是 revision \(expected)。请让 Agent 重新读取工程后生成方案。"
        case .missingTemplate:
            return "方案选择的写作模板已不存在，请让 Agent 重新读取模板库。"
        }
    }
}
