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
        workspace.project.updatedAt = Date()
        scheduleSave()
    }

    func updateBible(_ bible: StoryBible) {
        workspace.bible = bible
        scheduleSave()
    }

    func addVolume(_ volume: VolumeOutline) {
        workspace.volumes.append(volume)
        scheduleSave()
    }

    func updateVolume(_ volume: VolumeOutline) {
        if let index = workspace.volumes.firstIndex(where: { $0.id == volume.id }) {
            workspace.volumes[index] = volume
        } else {
            workspace.volumes.append(volume)
        }
        scheduleSave()
    }

    func addCharacter(_ character: NovelCore.Character) {
        workspace.characters.append(character)
        scheduleSave()
    }

    func updateCharacter(_ character: NovelCore.Character) {
        if let index = workspace.characters.firstIndex(where: { $0.id == character.id }) {
            workspace.characters[index] = character
        } else {
            workspace.characters.append(character)
        }
        scheduleSave()
    }

    func addWorldRule(_ rule: WorldRule) {
        workspace.worldRules.append(rule)
        scheduleSave()
    }

    func updateWorldRule(_ rule: WorldRule) {
        if let index = workspace.worldRules.firstIndex(where: { $0.id == rule.id }) {
            workspace.worldRules[index] = rule
        } else {
            workspace.worldRules.append(rule)
        }
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
        selectedChapterID = chapter.id
        scheduleSave()
    }

    func updateChapterCard(id: UUID, _ update: (inout ChapterCard) -> Void) {
        guard let index = workspace.chapters.firstIndex(where: { $0.id == id }) else { return }
        update(&workspace.chapters[index])
        workspace.chapters[index].updatedAt = Date()
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
