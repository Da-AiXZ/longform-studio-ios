import XCTest
@testable import NovelCore

final class TextAndDiffTests: XCTestCase {
    func testScannerFindsMetaLanguageAndDuplicateParagraph() {
        let paragraph = "这是一个足够长并且会被完整重复的测试段落，用来验证重复内容扫描功能。"
        let text = "作为AI，以下是正文。\n\(paragraph)\n\(paragraph)"
        let issues = LocalQualityScanner().scan(text: text, targetWords: 50)

        XCTAssertTrue(issues.contains { $0.title == "出现模型元话语" })
        XCTAssertTrue(issues.contains { $0.title == "重复段落" })
    }

    func testScannerFindsRepeatedSentence() {
        let sentence = "他在雨夜里听见同一声钟响"
        let issues = LocalQualityScanner().scan(text: "\(sentence)。\(sentence)。", targetWords: 30)
        XCTAssertTrue(issues.contains { $0.title == "重复句子" })
    }

    func testParagraphDiffMarksInsertAndDelete() {
        let result = ParagraphDiff.compare(old: "第一段\n第二段", new: "第一段\n替换段")
        XCTAssertEqual(result.map(\.kind), [.unchanged, .inserted, .deleted])
    }

    func testManuscriptImporterRecognizesChineseHeadings() {
        let sections = ManuscriptImporter.splitIntoChapters("第1章 起点\n正文一\n第2章 变化\n正文二")
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[1].title, "第2章 变化")
        XCTAssertEqual(sections[1].body, "正文二")
    }
}
