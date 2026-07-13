import XCTest
import NovelCore
@testable import LongformStudio

@MainActor
final class LongformStudioTests: XCTestCase {
    func testEndpointRejectsPlainHTTP() {
        let profile = AIEndpointProfile(name: "Local", endpoint: URL(string: "http://192.168.1.2/v1/chat/completions")!, model: "model")
        XCTAssertFalse(profile.isSecure)
    }

    func testDiagnosticRedactionRemovesAuthorizationAndAPIKey() {
        let input = "Authorization: Bearer sk-sensitive api_key=another-secret"
        let output = DiagnosticLogger.redactAuthorization(input)
        XCTAssertFalse(output.contains("sk-sensitive"))
        XCTAssertFalse(output.contains("another-secret"))
        XCTAssertTrue(output.contains("[REDACTED]"))
    }

    func testSettingsNeverSerializeKeyMaterial() throws {
        let suiteName = "LongformStudioTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)
        let profile = AIEndpointProfile(name: "Test", endpoint: URL(string: "https://example.com/v1/chat/completions")!, model: "model")
        try store.save(profile: profile, apiKey: nil)
        let data = try XCTUnwrap(defaults.data(forKey: "settings.v1"))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.localizedCaseInsensitiveContains("apiKey"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("secret"))
    }

    func testWorkflowExecutorCompletesAuditedChapterLoop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "LongformStudioTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        var profile = AIEndpointProfile(name: "Scripted", endpoint: URL(string: "https://example.com/v1/chat/completions")!, model: "scripted", streams: false)
        profile.keychainReference = "test-\(UUID().uuidString)"
        try settings.save(profile: profile, apiKey: "test-key")
        defer { try? settings.keychain.remove(reference: profile.keychainReference) }

        let repository = ProjectRepository(rootURL: root)
        let project = NovelProject(title: "闭环测试", platform: .qidian, genre: "玄幻", sellingPoint: "线索破局", targetWordCount: 100_000, protagonistGoal: "查明真相", targetChapterWords: 20)
        var workspace = try await repository.createProject(project)
        var chapter = ChapterCard(number: 1, title: "雨夜", goal: "取得线索", conflict: "追兵封路", turn: "敌人留下证据", hook: "幕后人现身", status: .drafting)
        let initial = ChapterVersion(chapterID: chapter.id, source: .manual, body: "")
        chapter.activeVersionID = initial.id
        chapter.versionIDs = [initial.id]
        workspace.chapters = [chapter]
        workspace.versions = [initial]
        let client = ScriptedAIClient()
        let session = ProjectSession(workspace: workspace, repository: repository, settings: settings, aiClient: client)
        let executor = WorkflowToolExecutor()

        let draft = try await executor.generateDraft(session: session, chapter: chapter)
        session.acceptVersion(chapterID: chapter.id, versionID: draft.version.id)
        let active = try XCTUnwrap(session.workspace.chapters.first)
        let reports = try await executor.runReviews(session: session, chapter: active)
        let facts = try await executor.extractFacts(session: session, chapter: active)
        let result = session.approveChapter(chapterID: active.id)

        XCTAssertEqual(reports.count, 4)
        XCTAssertTrue(reports.allSatisfy { $0.chapterVersionID == draft.version.id })
        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(result?.passed, true)
        XCTAssertEqual(session.workspace.chapters.first?.status, .approved)
        XCTAssertEqual(session.workspace.facts.first?.status, .accepted)
        XCTAssertFalse(session.workspace.versions.first { $0.id == initial.id }?.body == draft.text)
    }

    func testEditingReviewedVersionCreatesNewVersionAndInvalidatesOldReports() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let project = NovelProject(title: "版本测试", platform: .qidian, genre: "玄幻", sellingPoint: "", targetWordCount: 100_000, protagonistGoal: "")
        var workspace = try await repository.createProject(project)
        var chapter = ChapterCard(number: 1, title: "第一章")
        let version = ChapterVersion(chapterID: chapter.id, source: .manual, body: "原正文")
        chapter.activeVersionID = version.id
        chapter.versionIDs = [version.id]
        workspace.chapters = [chapter]
        workspace.versions = [version]
        workspace.reviews = [ReviewReport(chapterID: chapter.id, chapterVersionID: version.id, kind: .plot, scores: [.plotCausality: 90], issues: [], summary: "通过")]
        let session = ProjectSession(workspace: workspace, repository: repository, settings: SettingsStore())

        let newID = session.updateBody(chapterID: chapter.id, versionID: version.id, body: "修改后的正文")
        let updated = try XCTUnwrap(session.workspace.chapters.first)

        XCTAssertNotEqual(newID, version.id)
        XCTAssertEqual(updated.activeVersionID, newID)
        XCTAssertTrue(session.reviews(for: updated).isEmpty)
        XCTAssertEqual(session.workspace.versions.first { $0.id == version.id }?.body, "原正文")
    }
}

private final class ScriptedAIClient: AIChatClient {
    func complete(profile: AIEndpointProfile, apiKey: String, messages: [ChatMessage]) async throws -> AICompletion {
        let prompt = messages.map(\.content).joined(separator: "\n")
        if prompt.contains("只记录人物状态") {
            return AICompletion(content: "{\"facts\":[{\"subject\":\"林舟\",\"predicate\":\"持有\",\"value\":\"铜牌\",\"conflict_with_fact_id\":null}]}", finishReason: "stop")
        }
        if prompt.contains("逐项给出 0-100 分") {
            let scores = QualityDimension.allCases.map { "\"\($0.rawValue)\":90" }.joined(separator: ",")
            return AICompletion(content: "{\"scores\":{\(scores)},\"issues\":[],\"summary\":\"通过\"}", finishReason: "stop")
        }
        return AICompletion(content: "雨落青石街。林舟避开追兵，拿到铜牌，也看见幕后人的影子。", finishReason: "stop")
    }

    func stream(profile: AIEndpointProfile, apiKey: String, messages: [ChatMessage]) -> AsyncThrowingStream<AIStreamValue, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: AIClientError.invalidResponse)
        }
    }
}
