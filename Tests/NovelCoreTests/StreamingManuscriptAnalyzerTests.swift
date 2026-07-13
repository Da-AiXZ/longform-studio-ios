import XCTest
@testable import NovelCore

final class StreamingManuscriptAnalyzerTests: XCTestCase {
    func testUTF8AnalysisHandlesHeadingAcrossChunks() async throws {
        let url = temporaryURL(extension: "txt")
        defer { try? FileManager.default.removeItem(at: url) }
        let padding = String(repeating: "前文铺垫。", count: 700)
        let text = "第1章 开端\n\(padding)\n第2章 转折\n主角在雨夜得到新的线索。\n"
        try Data(text.utf8).write(to: url)
        let analyzer = StreamingManuscriptAnalyzer(chunkSize: 7)

        let index = try await analyzer.analyze(url: url)

        XCTAssertEqual(index.chapterMetrics.count, 2)
        XCTAssertEqual(index.chapterMetrics[1].title, "第2章 转折")
        XCTAssertEqual(index.analyzedCharacters, padding.count + "主角在雨夜得到新的线索。".count)
        XCTAssertGreaterThan(index.averageSentenceLength, 0)
        XCTAssertTrue(index.nodes.contains { $0.kind == "chapter" })
        XCTAssertTrue(index.nodes.contains { $0.kind == "structure" })
        XCTAssertTrue(index.edges.contains { $0.relation == "precedes" })
        XCTAssertTrue(index.edges.contains { $0.relation == "mentions" })
    }

    func testUTF16AnalysisDoesNotCorruptChineseAcrossChunks() async throws {
        let url = temporaryURL(extension: "txt")
        defer { try? FileManager.default.removeItem(at: url) }
        let text = "第1章 开端\r\n雨落在青石街上。\r\n第2章 追踪\r\n林舟追进旧城。"
        let data = try XCTUnwrap(text.data(using: .utf16LittleEndian))
        var withBOM = Data([0xFF, 0xFE])
        withBOM.append(data)
        try withBOM.write(to: url)
        let analyzer = StreamingManuscriptAnalyzer(chunkSize: 5)

        let index = try await analyzer.analyze(url: url)

        XCTAssertEqual(index.chapterMetrics.map(\.title), ["第1章 开端", "第2章 追踪"])
        XCTAssertEqual(index.analyzedCharacters, "雨落在青石街上。".count + "林舟追进旧城。".count)
    }

    func testFiveMillionCharacterInputProducesBoundedIndexAndNoSourceText() async throws {
        let url = temporaryURL(extension: "txt")
        defer { try? FileManager.default.removeItem(at: url) }
        let content = "主角进入城中调查线索并避开追兵。"
        let paragraph = content + "\n"
        let repeatCount = 5_000_000 / content.count + 1
        let handleData = Data(String(repeating: paragraph, count: repeatCount).utf8)
        try handleData.write(to: url)
        let analyzer = StreamingManuscriptAnalyzer(chunkSize: 64 * 1_024)

        let index = try await analyzer.analyze(url: url)
        let template = analyzer.makeLocalTemplate(from: index)
        let encodedTemplate = String(decoding: try JSONEncoder().encode(template), as: UTF8.self)

        XCTAssertGreaterThanOrEqual(index.analyzedCharacters, 5_000_000)
        XCTAssertLessThanOrEqual(index.nodes.count, 600)
        XCTAssertLessThanOrEqual(index.edges.count, 4_000)
        XCTAssertLessThanOrEqual(index.representativeEvidence.count, 40)
        XCTAssertFalse(encodedTemplate.contains(String(repeating: paragraph, count: 5)))
        XCTAssertLessThanOrEqual(index.estimatedSynthesisTokens, 80_000)
    }

    func testCancellationStopsAnalysis() async throws {
        let url = temporaryURL(extension: "txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(String(repeating: "正文段落。\n", count: 200_000).utf8).write(to: url)
        let analyzer = StreamingManuscriptAnalyzer(chunkSize: 4_096)
        let task = Task { try await analyzer.analyze(url: url) }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    private func temporaryURL(extension pathExtension: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(pathExtension)")
    }
}
