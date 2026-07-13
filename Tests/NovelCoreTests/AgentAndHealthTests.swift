import XCTest
@testable import NovelCore

final class AgentAndHealthTests: XCTestCase {
    func testAgentResponseDecodesLightweightProposalAndWhitelistedTool() throws {
        let json = """
        {
          "reply":"先确认这个方案。",
          "proposal":{
            "baseRevision":3,
            "genre":"玄幻",
            "sellingPoint":"失败会留下可利用的线索",
            "bible":{"premise":"小人物追查旧案"},
            "characters":[{"name":"林舟","role":"主角"}],
            "chapters":[{"number":1,"title":"雨夜","goal":"取得第一条线索","conflict":"追兵封路","turn":"线索来自敌人","hook":"幕后人现身"}]
          },
          "toolRequests":[{"tool":"readProjectSummary","arguments":{}}]
        }
        """

        let response = try AgentResponseParser.decode(json)

        XCTAssertEqual(response.proposal?.baseRevision, 3)
        XCTAssertEqual(response.proposal?.characters?.first?.name, "林舟")
        XCTAssertEqual(response.proposal?.chapters?.first?.hook, "幕后人现身")
        XCTAssertEqual(response.toolRequests.map(\.tool), [.readProjectSummary])
    }

    func testAgentResponseRejectsUnknownTool() {
        let json = """
        {"reply":"","proposal":null,"toolRequests":[{"tool":"deleteProject","arguments":{}}]}
        """
        XCTAssertThrowsError(try AgentResponseParser.decode(json))
    }

    func testRunScopeAndPausedRunRoundTrip() throws {
        let chapterID = UUID()
        let run = AgentRun(
            policy: .pass,
            scope: .chapterCount(3),
            status: .paused,
            chapterIDs: [chapterID],
            currentStepIndex: 1,
            steps: [
                AgentStep(tool: .manageChapterCard, title: "检查章卡", status: .completed, chapterID: chapterID),
                AgentStep(tool: .generateDraft, title: "生成正文", status: .pending, chapterID: chapterID)
            ],
            maximumModelCalls: 32,
            modelCallsUsed: 2
        )
        let data = try JSONEncoder().encode(run)
        let decoded = try JSONDecoder().decode(AgentRun.self, from: data)

        XCTAssertEqual(decoded.scope, .chapterCount(3))
        XCTAssertEqual(decoded.status, .paused)
        XCTAssertEqual(decoded.currentStepIndex, 1)
        XCTAssertEqual(decoded.modelCallsUsed, 2)
    }

    func testLegacyWorkspaceDefaultsToAgentModeAndEmptySession() throws {
        let json = """
        {
          "project":{
            "id":"00000000-0000-0000-0000-000000000001",
            "schemaVersion":1,
            "title":"旧工程",
            "platform":"qidian",
            "genre":"玄幻",
            "sellingPoint":"破局",
            "targetWordCount":1000000,
            "protagonistGoal":"回家",
            "restrictedContent":[],
            "perspective":"thirdPersonLimited",
            "targetChapterWords":2500,
            "createdAt":"2026-01-01T00:00:00Z",
            "updatedAt":"2026-01-01T00:00:00Z"
          }
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let workspace = try decoder.decode(ProjectWorkspace.self, from: Data(json.utf8))

        XCTAssertEqual(workspace.project.planRevision, 0)
        XCTAssertEqual(workspace.preferredMode, .agent)
        XCTAssertEqual(workspace.agentSession.policy, .supervised)
        XCTAssertTrue(workspace.agentSession.messages.isEmpty)
        XCTAssertNil(workspace.appliedTemplate)
    }

    func testIntegrityValidatorFindsInvalidVersionReferenceAndRunIndex() {
        let project = NovelProject(title: "测试", platform: .qidian, genre: "玄幻", sellingPoint: "", targetWordCount: 100_000, protagonistGoal: "")
        var chapter = ChapterCard(number: 1, title: "第一章")
        chapter.activeVersionID = UUID()
        chapter.versionIDs = [chapter.activeVersionID!]
        let run = AgentRun(policy: .pass, scope: .currentChapter, status: .paused, chapterIDs: [chapter.id], currentStepIndex: 2, steps: [], maximumModelCalls: 10)
        let workspace = ProjectWorkspace(project: project, chapters: [chapter], agentSession: AgentSession(runs: [run], activeRunID: run.id))

        let checks = WorkspaceIntegrityValidator.validate(workspace)

        XCTAssertEqual(checks.first { $0.id == "DATA-001" }?.status, .failed)
        XCTAssertEqual(checks.first { $0.id == "AGENT-001" }?.status, .failed)
    }

    func testHealthReportBoundsDiagnosticText() {
        let secret = "Authorization: Bearer secret-value"
        let report = HealthReport(applicationVersion: "0.2.0", buildNumber: "2", systemVersion: "test", projectID: nil, checks: [], recentDiagnostics: [String(repeating: "x", count: 900), secret])

        XCTAssertEqual(report.recentDiagnostics.first?.count, 500)
        XCTAssertFalse(report.recentDiagnostics.last?.contains("secret-value") == true)
        XCTAssertTrue(report.markdown().contains("长篇工坊运行自检报告"))
    }
}
