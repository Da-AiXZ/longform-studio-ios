import XCTest
@testable import NovelCore

final class PromptCompilerTests: XCTestCase {
    func testPromptContainsApprovedContextAndNoProviderSpecificFields() {
        let project = NovelProject(title: "测试", platform: .fanqie, genre: "都市异能", sellingPoint: "每次失败都会获得线索", targetWordCount: 500_000, protagonistGoal: "查清能力来源")
        let context = ContextSelection(
            items: [ContextItem(id: "fact", category: .continuity, title: "正式事实", text: "主角左手受伤。", priority: 100, required: true)],
            estimatedInputTokens: 20,
            availableInputTokens: 1_000,
            droppedItemIDs: []
        )
        let request = PromptRequest(task: .chapterDraft, project: project, instruction: "写出第3章。", context: context)
        let messages = PromptCompiler.compile(request)

        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages[0].content.contains("番茄男频"))
        XCTAssertTrue(messages[1].content.contains("主角左手受伤"))
        XCTAssertFalse(messages[1].content.contains("response_format"))
    }

    func testCodeFenceStripping() {
        XCTAssertEqual(PromptCompiler.stripMarkdownCodeFence("```json\n{\"ok\":true}\n```"), "{\"ok\":true}")
    }
}
