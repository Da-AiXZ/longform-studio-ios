import XCTest
@testable import NovelCore

final class QualityGateTests: XCTestCase {
    func testQidianProfileWeightsSumToOne() {
        XCTAssertEqual(BuiltInPlatformProfiles.qidian.weights.values.reduce(0, +), 1, accuracy: 0.0001)
        XCTAssertEqual(BuiltInPlatformProfiles.fanqie.weights.values.reduce(0, +), 1, accuracy: 0.0001)
    }

    func testGateBlocksHighIssue() {
        let profile = BuiltInPlatformProfiles.qidian
        let scores = Dictionary(uniqueKeysWithValues: profile.weights.keys.map { ($0, 90.0) })
        let report = ReviewReport(
            chapterID: UUID(),
            kind: .continuity,
            scores: scores,
            issues: [ReviewIssue(severity: .high, dimension: .continuity, title: "人物死而复生")],
            summary: "存在硬冲突"
        )

        let result = QualityGate.evaluate(reports: [report], localIssues: [], profile: profile)

        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.blockingIssues.count, 1)
        XCTAssertEqual(result.totalScore, 90, accuracy: 0.001)
    }

    func testManualOverrideRequiresNonEmptyReason() {
        let profile = BuiltInPlatformProfiles.qidian
        let noReason = QualityGate.evaluate(reports: [], localIssues: [], profile: profile, manualOverrideReason: "  ")
        let withReason = QualityGate.evaluate(reports: [], localIssues: [], profile: profile, manualOverrideReason: "编辑确认后保留")

        XCTAssertFalse(noReason.passed)
        XCTAssertTrue(withReason.passed)
        XCTAssertEqual(withReason.overrideReason, "编辑确认后保留")
    }
}
