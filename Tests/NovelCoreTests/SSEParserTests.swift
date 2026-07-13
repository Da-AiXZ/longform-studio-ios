import XCTest
@testable import NovelCore

final class SSEParserTests: XCTestCase {
    func testParsesFragmentedEventsAndDoneMarker() throws {
        var parser = SSEParser()
        let first = try parser.feed("data: {\"choices\":[{\"delta\":{\"content\":\"你\"},\"finish_reason\":null}]}\n")
        let second = try parser.feed("\ndata: {\"choices\":[{\"delta\":{\"content\":\"好\"},\"finish_reason\":null}]}\n\ndata: [DONE]\n\n")

        XCTAssertTrue(first.isEmpty)
        XCTAssertEqual(second, [.text("你"), .text("好"), .done])
    }

    func testFinishReasonIsReported() throws {
        var parser = SSEParser()
        let events = try parser.feed("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}\n\n")
        XCTAssertEqual(events, [.finished("length")])
    }

    func testContinuationRemovesOverlap() {
        XCTAssertEqual(TextContinuationMerger.merge(existing: "他推门而入。风雪正盛。", continuation: "风雪正盛。他看见一盏灯。"), "他推门而入。风雪正盛。他看见一盏灯。")
    }
}
