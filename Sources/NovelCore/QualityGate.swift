import Foundation

public struct QualityGateResult: Equatable, Sendable {
    public var passed: Bool
    public var totalScore: Double
    public var missingDimensions: [QualityDimension]
    public var belowThreshold: [QualityDimension]
    public var blockingIssues: [ReviewIssue]
    public var overrideReason: String?

    public init(passed: Bool, totalScore: Double, missingDimensions: [QualityDimension], belowThreshold: [QualityDimension], blockingIssues: [ReviewIssue], overrideReason: String? = nil) {
        self.passed = passed
        self.totalScore = totalScore
        self.missingDimensions = missingDimensions
        self.belowThreshold = belowThreshold
        self.blockingIssues = blockingIssues
        self.overrideReason = overrideReason
    }
}

public enum QualityGate {
    public static func evaluate(
        reports: [ReviewReport],
        localIssues: [ReviewIssue],
        profile: PlatformProfile,
        manualOverrideReason: String? = nil
    ) -> QualityGateResult {
        var scoreBuckets: [QualityDimension: [Double]] = [:]
        for report in reports {
            for (dimension, score) in report.scores {
                scoreBuckets[dimension, default: []].append(min(100, max(0, score)))
            }
        }

        let scores = scoreBuckets.mapValues { values in
            values.reduce(0, +) / Double(values.count)
        }
        let requiredDimensions = Set(profile.weights.keys)
        let missing = requiredDimensions.filter { scores[$0] == nil }.sorted { $0.rawValue < $1.rawValue }
        let below = requiredDimensions.filter { (scores[$0] ?? 0) < profile.minimumDimensionScore }.sorted { $0.rawValue < $1.rawValue }
        let total = profile.weights.reduce(0.0) { partial, item in
            partial + (scores[item.key] ?? 0) * item.value
        }
        let allIssues = reports.flatMap(\.issues) + localIssues
        let blocking = allIssues.filter { !$0.resolved && $0.severity.rank >= ReviewSeverity.high.rank }
        let automaticallyPassed = missing.isEmpty && below.isEmpty && blocking.isEmpty && total >= profile.minimumTotalScore
        let reason = manualOverrideReason?.trimmingCharacters(in: .whitespacesAndNewlines)
        let overridden = reason.map { !$0.isEmpty } ?? false

        return QualityGateResult(
            passed: automaticallyPassed || overridden,
            totalScore: total,
            missingDimensions: missing,
            belowThreshold: below,
            blockingIssues: blocking,
            overrideReason: overridden ? reason : nil
        )
    }
}
