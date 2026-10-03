import XCTest
@testable import NovelCore

final class ProjectRepositoryTests: XCTestCase {
    func testRoundTripAndArchiveExcludeSecretsByConstruction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let project = NovelProject(title: "测试长篇", platform: .qidian, genre: "玄幻", sellingPoint: "小人物破局", targetWordCount: 1_000_000, protagonistGoal: "找到失踪的父亲")
        var workspace = try await repository.createProject(project)
        var chapter = ChapterCard(number: 1, title: "雨夜来客")
        let version = ChapterVersion(chapterID: chapter.id, source: .manual, body: "雨落在青石街上。")
        chapter.activeVersionID = version.id
        chapter.versionIDs = [version.id]
        workspace.chapters = [chapter]
        workspace.versions = [version]
        try await repository.save(workspace)

        let loaded = try await repository.loadProject(id: project.id)
        let loadedVersion = try XCTUnwrap(loaded.activeVersion(for: loaded.chapters[0]))
        XCTAssertFalse(loadedVersion.isBodyLoaded)
        XCTAssertTrue(loadedVersion.body.isEmpty)
        XCTAssertEqual(loadedVersion.characterCount, 7)

        let lazyBody = try await repository.loadVersionBody(projectID: project.id, versionID: loadedVersion.id)
        let archive = try await repository.exportArchive(loaded)
        let archiveText = String(decoding: archive, as: UTF8.self)
        let decodedArchive = try JSONDecoder.iso8601.decode(ProjectArchive.self, from: archive)

        XCTAssertEqual(lazyBody, "雨落在青石街上。")
        XCTAssertEqual(decodedArchive.workspace.versions.first?.body, "雨落在青石街上。")
        XCTAssertFalse(archiveText.localizedCaseInsensitiveContains("apiKey"))
        XCTAssertFalse(archiveText.localizedCaseInsensitiveContains("secret"))
    }

    func testVersionOneArchiveImportsIntoVersionTwoWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let project = NovelProject(schemaVersion: 1, title: "旧备份", platform: .qidian, genre: "玄幻", sellingPoint: "", targetWordCount: 100_000, protagonistGoal: "")
        let archive = ProjectArchive(archiveVersion: 1, workspace: ProjectWorkspace(project: project))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let imported = try await repository.importArchive(encoder.encode(archive))

        XCTAssertEqual(imported.project.schemaVersion, ProjectRepository.currentSchemaVersion)
        XCTAssertEqual(imported.preferredMode, .agent)
        XCTAssertTrue(imported.agentSession.messages.isEmpty)
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
