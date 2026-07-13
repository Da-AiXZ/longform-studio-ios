import XCTest
@testable import NovelCore

final class ContextBuilderTests: XCTestCase {
    func testRequiredAndHighPriorityItemsWinTokenBudget() {
        let items = [
            ContextItem(id: "old", category: .earlierSummary, title: "旧摘要", text: String(repeating: "旧", count: 2_000), priority: 1),
            ContextItem(id: "bible", category: .storyBible, title: "故事圣经", text: String(repeating: "核心", count: 200), priority: 100, required: true),
            ContextItem(id: "previous", category: .previousChapter, title: "上一章", text: String(repeating: "正文", count: 600), priority: 90)
        ]

        let result = ContextBuilder.select(from: items, contextLimit: 2_000, outputReserve: 300, safetyRatio: 0.15)

        XCTAssertTrue(result.items.contains { $0.id == "bible" })
        XCTAssertTrue(result.items.contains { $0.id == "previous" })
        XCTAssertTrue(result.droppedItemIDs.contains("old"))
        XCTAssertLessThanOrEqual(result.estimatedInputTokens, result.availableInputTokens)
    }

    func testHundredChapterSelectionStaysInsideBudget() {
        let query = "主角进入皇城调查失踪案"
        let items = (1...100).map { number in
            ContextItem(
                id: "chapter-\(number)",
                category: .earlierSummary,
                title: "第\(number)章摘要",
                text: number == 78 ? "主角在皇城追查失踪的炼器师。" : "主角完成第\(number)阶段修炼并返回驻地。",
                priority: 20,
                relevance: ContextBuilder.relevance(of: number == 78 ? "皇城失踪炼器师调查" : "修炼返回驻地", to: query)
            )
        }

        let result = ContextBuilder.select(from: items, contextLimit: 1_200, outputReserve: 300)

        XCTAssertLessThanOrEqual(result.estimatedInputTokens, result.availableInputTokens)
        XCTAssertEqual(result.items.first?.id, "chapter-78")
        XCTAssertFalse(result.droppedItemIDs.isEmpty)
    }
}
