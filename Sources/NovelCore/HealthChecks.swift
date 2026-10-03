import Foundation

public enum HealthCheckStatus: String, Codable, Hashable, Sendable {
    case passed
    case warning
    case failed
}

public struct HealthCheckItem: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var status: HealthCheckStatus
    public var errorDomain: String?
    public var errorCode: String?
    public var step: String
    public var reproduction: String
    public var detail: String
    public var suggestion: String

    public init(id: String, title: String, status: HealthCheckStatus, errorDomain: String? = nil, errorCode: String? = nil, step: String, reproduction: String = "", detail: String, suggestion: String = "") {
        self.id = id
        self.title = title
        self.status = status
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.step = step
        self.reproduction = reproduction
        self.detail = detail
        self.suggestion = suggestion
    }
}

public struct HealthReport: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var applicationVersion: String
    public var buildNumber: String
    public var systemVersion: String
    public var projectID: UUID?
    public var checks: [HealthCheckItem]
    public var recentDiagnostics: [String]

    public init(id: UUID = UUID(), createdAt: Date = Date(), applicationVersion: String, buildNumber: String, systemVersion: String, projectID: UUID?, checks: [HealthCheckItem], recentDiagnostics: [String]) {
        self.id = id
        self.createdAt = createdAt
        self.applicationVersion = applicationVersion
        self.buildNumber = buildNumber
        self.systemVersion = systemVersion
        self.projectID = projectID
        self.checks = checks.map { check in
            var value = check
            value.detail = Self.redact(check.detail)
            value.reproduction = check.reproduction.isEmpty && check.status != .passed
                ? "在应用内重新运行检查 \(check.id)。"
                : Self.redact(check.reproduction)
            value.suggestion = Self.redact(check.suggestion)
            return value
        }
        self.recentDiagnostics = recentDiagnostics.map { Self.redact(String($0.prefix(500))) }
    }

    public var overallStatus: HealthCheckStatus {
        if checks.contains(where: { $0.status == .failed }) { return .failed }
        if checks.contains(where: { $0.status == .warning }) { return .warning }
        return .passed
    }

    public func markdown() -> String {
        var lines = [
            "# 长篇工坊运行自检报告",
            "",
            "- 时间：\(ISO8601DateFormatter().string(from: createdAt))",
            "- 应用：\(applicationVersion) (\(buildNumber))",
            "- 系统：\(systemVersion)",
            "- 总体：\(overallStatus.rawValue)",
            ""
        ]
        for check in checks {
            lines.append("## [\(check.status.rawValue.uppercased())] \(check.id) · \(check.title)")
            lines.append("")
            lines.append("- 步骤：\(check.step)")
            if !check.reproduction.isEmpty { lines.append("- 复现：\(check.reproduction)") }
            if let domain = check.errorDomain { lines.append("- 错误域：\(domain)") }
            if let code = check.errorCode { lines.append("- 错误码：\(code)") }
            lines.append("- 结果：\(check.detail)")
            if !check.suggestion.isEmpty { lines.append("- 建议：\(check.suggestion)") }
            lines.append("")
        }
        if !recentDiagnostics.isEmpty {
            lines.append("## 最近脱敏诊断")
            lines.append("")
            for value in recentDiagnostics { lines.append("- \(value)") }
        }
        return lines.joined(separator: "\n")
    }

    private static func redact(_ input: String) -> String {
        let patterns = [
            "(?i)(Authorization\\s*[:=]\\s*)([^\\s,}]+(?:\\s+[^\\s,}]+)?)",
            "(?i)(api[-_ ]?key\\s*[:=]\\s*)([^\\s,}]+)",
            "(?i)(\\b(?:sk|key)[-_])[A-Za-z0-9_-]{12,}"
        ]
        let redacted = patterns.reduce(input) { current, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return current }
            let range = NSRange(current.startIndex..<current.endIndex, in: current)
            return regex.stringByReplacingMatches(in: current, range: range, withTemplate: "$1[REDACTED]")
        }
        let chineseCount = redacted.unicodeScalars.filter { (0x3400...0x9FFF).contains($0.value) }.count
        return chineseCount > 60 ? "[LONG_TEXT_REDACTED]" : redacted
    }
}

public enum WorkspaceIntegrityValidator {
    public static func validate(_ workspace: ProjectWorkspace) -> [HealthCheckItem] {
        var checks: [HealthCheckItem] = []
        let versionIDs = Set(workspace.versions.map(\.id))
        let chapterIDs = Set(workspace.chapters.map(\.id))
        let missingVersionReferences = workspace.chapters.flatMap { chapter in
            chapter.versionIDs.filter { !versionIDs.contains($0) }.map { "\(chapter.number):\($0.uuidString)" }
        }
        let invalidActiveVersions = workspace.chapters.filter { chapter in
            guard let active = chapter.activeVersionID else { return false }
            return !versionIDs.contains(active) || !chapter.versionIDs.contains(active)
        }
        let orphanVersions = workspace.versions.filter { !chapterIDs.contains($0.chapterID) }
        let duplicateChapterNumbers = Dictionary(grouping: workspace.chapters, by: \.number).filter { $0.value.count > 1 }.keys.sorted()

        checks.append(HealthCheckItem(
            id: "DATA-001",
            title: "章节版本引用",
            status: missingVersionReferences.isEmpty && invalidActiveVersions.isEmpty ? .passed : .failed,
            errorDomain: missingVersionReferences.isEmpty && invalidActiveVersions.isEmpty ? nil : "WorkspaceIntegrity",
            errorCode: missingVersionReferences.isEmpty && invalidActiveVersions.isEmpty ? nil : "INVALID_VERSION_REFERENCE",
            step: "检查章卡的 versionIDs 与 activeVersionID",
            detail: missingVersionReferences.isEmpty && invalidActiveVersions.isEmpty ? "全部章节版本引用有效。" : "发现 \(missingVersionReferences.count) 个缺失版本引用和 \(invalidActiveVersions.count) 个无效当前版本。",
            suggestion: "导出工程报告并停止自动批准，修复引用后再继续。"
        ))
        checks.append(HealthCheckItem(
            id: "DATA-002",
            title: "孤立版本",
            status: orphanVersions.isEmpty ? .passed : .warning,
            step: "检查每个版本所属章节",
            detail: orphanVersions.isEmpty ? "没有孤立正文版本。" : "发现 \(orphanVersions.count) 个找不到所属章节的版本。",
            suggestion: "保留备份后检查工程迁移记录。"
        ))
        checks.append(HealthCheckItem(
            id: "DATA-003",
            title: "章节序号",
            status: duplicateChapterNumbers.isEmpty ? .passed : .warning,
            step: "检查章节编号唯一性",
            detail: duplicateChapterNumbers.isEmpty ? "章节编号没有重复。" : "重复编号：\(duplicateChapterNumbers.map(String.init).joined(separator: "、"))。",
            suggestion: "在手动工作台调整重复章节编号。"
        ))

        let activeRun = workspace.agentSession.activeRunID.flatMap { id in workspace.agentSession.runs.first { $0.id == id } }
        let runIsRecoverable = activeRun.map { run in run.currentStepIndex >= 0 && run.currentStepIndex <= run.steps.count } ?? true
        checks.append(HealthCheckItem(
            id: "AGENT-001",
            title: "Agent 队列恢复",
            status: runIsRecoverable ? .passed : .failed,
            errorDomain: runIsRecoverable ? nil : "AgentState",
            errorCode: runIsRecoverable ? nil : "INVALID_STEP_INDEX",
            step: "检查活动任务与当前步骤",
            detail: runIsRecoverable ? "Agent 任务状态可恢复。" : "活动任务的步骤位置超出范围。",
            suggestion: "取消损坏的任务并重新选择执行范围。"
        ))

        let templateIsValid = workspace.appliedTemplate.map { !$0.template.name.isEmpty && !$0.template.sourceHash.isEmpty } ?? true
        checks.append(HealthCheckItem(
            id: "TPL-001",
            title: "项目模板快照",
            status: templateIsValid ? .passed : .warning,
            step: "检查已应用模板的名称与来源哈希",
            detail: templateIsValid ? "项目模板快照有效。" : "模板快照缺少名称或来源哈希。",
            suggestion: "重新从全局模板库选择模板。"
        ))
        return checks
    }
}
