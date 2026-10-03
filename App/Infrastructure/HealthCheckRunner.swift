import Foundation
import UIKit
import NovelCore

@MainActor
final class HealthCheckRunner {
    private let indexStore: ManuscriptIndexStore

    init(indexStore: ManuscriptIndexStore = .live()) {
        self.indexStore = indexStore
    }

    func run(session: ProjectSession?, settings: SettingsStore, includeNetworkTest: Bool = false) async -> HealthReport {
        var checks: [HealthCheckItem] = []
        if let session {
            checks.append(contentsOf: WorkspaceIntegrityValidator.validate(session.workspace))
            checks.append(await projectRoundTripCheck(session: session))
            checks.append(fileProtectionCheck(session: session))
        } else {
            checks.append(HealthCheckItem(id: "DATA-000", title: "工程检查", status: .warning, step: "读取当前工程", detail: "未打开作品，已跳过工程级检查。", suggestion: "在作品内运行自检可获得完整结果。"))
        }
        checks.append(modelConfigurationCheck(settings: settings))
        if includeNetworkTest { checks.append(await modelNetworkCheck(settings: settings)) }
        checks.append(keychainProbe())
        checks.append(diskSpaceCheck())
        checks.append(temporaryDirectoryCheck())
        checks.append(await indexCheck())
        checks.append(await templateIndexLinkCheck(settings: settings))

        let allEntries = await DiagnosticLogger.shared.allEntries()
        let recentEntries = Array(allEntries.suffix(20))
        checks.append(recentNetworkErrorCheck(entries: recentEntries))
        let diagnostics = recentEntries.map {
            "\(ISO8601DateFormatter().string(from: $0.timestamp)) [\($0.category)] \($0.message)"
        }
        let info = Bundle.main.infoDictionary
        return HealthReport(
            applicationVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
            buildNumber: info?["CFBundleVersion"] as? String ?? "unknown",
            systemVersion: "iOS \(UIDevice.current.systemVersion) · \(UIDevice.current.model)",
            projectID: session?.id,
            checks: checks,
            recentDiagnostics: diagnostics
        )
    }

    func export(_ report: HealthReport, format: ReportFormat) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LongformStudio-Health-\(report.id.uuidString).\(format.extensionName)")
        switch format {
        case .markdown:
            try Data(report.markdown().utf8).write(to: url, options: [.atomic, .completeFileProtection])
        case .json:
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: url, options: [.atomic, .completeFileProtection])
        }
        return url
    }

    enum ReportFormat { case markdown, json
        var extensionName: String {
            switch self { case .markdown: return "md"; case .json: return "json" }
        }
    }

    private func projectRoundTripCheck(session: ProjectSession) async -> HealthCheckItem {
        do {
            try await session.repository.validateProjectStorage(session.workspace)
            return HealthCheckItem(id: "DATA-010", title: "工程存储与编码", status: .passed, step: "编码并解码工程元数据，检查每个正文文件引用", detail: "工程元数据可重新读取，正文文件引用存在；未将全部正文加载进内存。")
        } catch {
            return HealthCheckItem(id: "DATA-010", title: "工程存储与编码", status: .failed, errorDomain: (error as NSError).domain, errorCode: String((error as NSError).code), step: "编码并解码工程元数据，检查每个正文文件引用", detail: error.localizedDescription, suggestion: "立即保留现有工程目录并转发本报告。")
        }
    }

    private func fileProtectionCheck(session: ProjectSession) -> HealthCheckItem {
        let directory = session.repository.projectDirectory(session.id)
        let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path)
        let protection = attributes?[.protectionKey] as? FileProtectionType
        let passed = protection != nil
        return HealthCheckItem(id: "SEC-001", title: "工程文件保护", status: passed ? .passed : .warning, step: "读取工程目录 Data Protection 属性", detail: passed ? "工程目录已设置 iOS 文件保护。" : "未能读取工程目录的文件保护属性。", suggestion: passed ? "" : "保存一次工程后重新运行自检。")
    }

    private func modelConfigurationCheck(settings: SettingsStore) -> HealthCheckItem {
        let secure = settings.profiles.filter(\.isSecure)
        let status: HealthCheckStatus = secure.isEmpty ? .warning : .passed
        return HealthCheckItem(id: "AI-001", title: "模型配置", status: status, step: "检查 HTTPS Endpoint 与角色默认值", detail: secure.isEmpty ? "没有可用的 HTTPS 模型配置。" : "发现 \(secure.count) 个 HTTPS 模型配置；未发起收费网络请求。", suggestion: secure.isEmpty ? "在设置中完成首次模型接入。" : "")
    }

    private func modelNetworkCheck(settings: SettingsStore) async -> HealthCheckItem {
        guard let profile = settings.profiles.first(where: \.isSecure) else {
            return HealthCheckItem(id: "AI-002", title: "真实模型连接", status: .warning, step: "发送一次最小 Chat Completions 请求", detail: "没有可测试的 HTTPS 模型配置。", suggestion: "先添加模型配置。")
        }
        do {
            let key = try settings.keychain.value(for: profile.keychainReference) ?? ""
            var testProfile = profile
            testProfile.outputTokenLimit = 16
            testProfile.temperature = 0
            let completion = try await OpenAICompatibleClient().complete(profile: testProfile, apiKey: key, messages: [ChatMessage(role: "user", content: "只回复 OK")])
            return HealthCheckItem(id: "AI-002", title: "真实模型连接", status: .passed, step: "发送一次最小 Chat Completions 请求", detail: "接口返回 \(completion.content.count) 个字符。此次检查可能产生少量费用。")
        } catch {
            return HealthCheckItem(id: "AI-002", title: "真实模型连接", status: .failed, errorDomain: (error as NSError).domain, errorCode: String((error as NSError).code), step: "发送一次最小 Chat Completions 请求", detail: error.localizedDescription, suggestion: "检查 Endpoint、模型名、API Key、网络和服务商兼容性。")
        }
    }

    private func keychainProbe() -> HealthCheckItem {
        let store = KeychainStore()
        let reference = "health-check-\(UUID().uuidString)"
        do {
            try store.set("probe", for: reference)
            let value = try store.value(for: reference)
            try store.remove(reference: reference)
            guard value == "probe" else { throw CocoaError(.coderReadCorrupt) }
            return HealthCheckItem(id: "SEC-002", title: "Keychain 读写", status: .passed, step: "写入并删除一次临时探针", detail: "Keychain 临时探针读写成功，未读取模型密钥。")
        } catch {
            try? store.remove(reference: reference)
            return HealthCheckItem(id: "SEC-002", title: "Keychain 读写", status: .failed, errorDomain: (error as NSError).domain, errorCode: String((error as NSError).code), step: "写入并删除一次临时探针", detail: error.localizedDescription, suggestion: "检查设备锁屏密码与应用 Keychain 权限。")
        }
    }

    private func diskSpaceCheck() -> HealthCheckItem {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return HealthCheckItem(id: "SYS-001", title: "可用磁盘空间", status: .warning, step: "读取 Application Support 所在卷容量", detail: "无法定位 Application Support 目录。", suggestion: "重启应用后重新运行自检。")
        }
        let values = try? base.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let bytes = values?.volumeAvailableCapacityForImportantUsage ?? 0
        let warning = bytes < 500 * 1_024 * 1_024
        return HealthCheckItem(id: "SYS-001", title: "可用磁盘空间", status: warning ? .warning : .passed, step: "读取 Application Support 所在卷容量", detail: "可用约 \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))。", suggestion: warning ? "清理空间后再分析大型小说或连续生成多章。" : "")
    }

    private func indexCheck() async -> HealthCheckItem {
        do {
            let count = try await indexStore.validate()
            return HealthCheckItem(id: "IDX-001", title: "长篇关系索引", status: .passed, step: "解码全部本地索引元数据", detail: "\(count) 个索引文件可读取。")
        } catch {
            return HealthCheckItem(id: "IDX-001", title: "长篇关系索引", status: .warning, errorDomain: (error as NSError).domain, errorCode: String((error as NSError).code), step: "解码全部本地索引元数据", detail: error.localizedDescription, suggestion: "删除对应模板并重新分析来源文件。")
        }
    }

    private func recentNetworkErrorCheck(entries: [DiagnosticEntry]) -> HealthCheckItem {
        let network = entries.filter { entry in
            entry.category.localizedCaseInsensitiveContains("AI") ||
            entry.message.localizedCaseInsensitiveContains("HTTP") ||
            entry.message.localizedCaseInsensitiveContains("网络") ||
            entry.message.localizedCaseInsensitiveContains("timeout")
        }
        return HealthCheckItem(
            id: "AI-003",
            title: "近期网络错误",
            status: network.isEmpty ? .passed : .warning,
            step: "检查最近 20 条持久化脱敏诊断",
            reproduction: network.isEmpty ? "" : "重新执行最近失败的 Agent 或模型连接操作。",
            detail: network.isEmpty ? "近期诊断中没有模型或网络错误。" : "发现 \(network.count) 条可能与模型或网络有关的记录。",
            suggestion: network.isEmpty ? "" : "导出本报告，并检查 Endpoint、服务状态和网络环境。"
        )
    }

    private func templateIndexLinkCheck(settings: SettingsStore) async -> HealthCheckItem {
        var missing: [String] = []
        for template in settings.writingTemplates {
            if !(await indexStore.contains(sourceHash: template.sourceHash)) { missing.append(template.name) }
        }
        return HealthCheckItem(
            id: "TPL-002",
            title: "全局模板与索引",
            status: missing.isEmpty ? .passed : .warning,
            step: "检查每个全局模板的来源索引",
            detail: missing.isEmpty ? "全部模板均有关联索引。" : "缺少索引的模板：\(missing.joined(separator: "、"))。",
            suggestion: missing.isEmpty ? "" : "模板仍可写作使用；如需检索证据，请重新分析来源文件。"
        )
    }

    private func temporaryDirectoryCheck() -> HealthCheckItem {
        let root = FileManager.default.temporaryDirectory
        let stale = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []).filter { url in
            guard url.lastPathComponent.hasPrefix("LongformStudio-Analysis-") else { return false }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return Date().timeIntervalSince(date) > 24 * 60 * 60
        }
        return HealthCheckItem(
            id: "TMP-001",
            title: "分析临时目录",
            status: stale.isEmpty ? .passed : .warning,
            step: "检查超过 24 小时的分析临时目录",
            detail: stale.isEmpty ? "没有遗留的长篇正文临时目录。" : "发现 \(stale.count) 个过期临时目录。",
            suggestion: stale.isEmpty ? "" : "重启应用后重新运行自检；仍存在时可转发报告。"
        )
    }
}
