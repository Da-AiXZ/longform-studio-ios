import SwiftUI
import NovelCore

struct HealthReportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: SettingsStore
    let session: ProjectSession?
    @State private var report: HealthReport?
    @State private var shareURL: URL?
    @State private var errorMessage: String?
    @State private var includeNetworkTest = false
    private let runner: HealthCheckRunner

    init(session: ProjectSession?, indexStore: ManuscriptIndexStore = .live()) {
        self.session = session
        self.runner = HealthCheckRunner(indexStore: indexStore)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let report {
                    List {
                        Section {
                            Label(statusText(report.overallStatus), systemImage: statusIcon(report.overallStatus))
                                .font(.headline)
                                .foregroundStyle(statusColor(report.overallStatus))
                            Toggle("测试真实模型连接", isOn: $includeNetworkTest)
                            Button { Task { await runChecks() } } label: {
                                Label("重新运行", systemImage: "arrow.clockwise")
                            }
                            Text("模型连接测试默认关闭；开启后会发送一次最小请求，可能产生少量费用。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(report.checks) { check in
                            Section("\(check.id) · \(check.title)") {
                                Label(statusText(check.status), systemImage: statusIcon(check.status))
                                    .foregroundStyle(statusColor(check.status))
                                Text(check.detail)
                                if !check.suggestion.isEmpty { Text(check.suggestion).font(.footnote).foregroundStyle(.secondary) }
                            }
                        }
                    }
                } else {
                    ProgressView("正在运行自检")
                }
            }
            .navigationTitle("运行自检")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                if let report {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button { export(report, format: .markdown) } label: { Label("Markdown", systemImage: "doc.text") }
                            Button { export(report, format: .json) } label: { Label("JSON", systemImage: "curlybraces") }
                        } label: { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("导出自检报告")
                    }
                }
            }
        }
        .task { await runChecks() }
        .sheet(item: Binding(get: { shareURL.map(HealthShareFile.init) }, set: { shareURL = $0?.url })) { file in
            ShareSheet(items: [file.url])
        }
        .alert("导出失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "未知错误") }
    }

    private func export(_ report: HealthReport, format: HealthCheckRunner.ReportFormat) {
        do { shareURL = try runner.export(report, format: format) }
        catch { errorMessage = error.localizedDescription }
    }

    private func runChecks() async {
        report = nil
        let result = await runner.run(session: session, settings: settings, includeNetworkTest: includeNetworkTest)
        report = result
        if let session {
            let failed = result.checks.filter { $0.status == .failed }.count
            let warnings = result.checks.filter { $0.status == .warning }.count
            session.appendAgentMessage(AgentMessage(role: .tool, kind: .report, content: "运行自检完成：\(failed) 项失败，\(warnings) 项需注意。详细报告可在自检页面导出。"))
        }
    }

    private func statusText(_ status: HealthCheckStatus) -> String {
        switch status { case .passed: return "通过"; case .warning: return "需注意"; case .failed: return "失败" }
    }
    private func statusIcon(_ status: HealthCheckStatus) -> String {
        switch status { case .passed: return "checkmark.circle.fill"; case .warning: return "exclamationmark.triangle.fill"; case .failed: return "xmark.octagon.fill" }
    }
    private func statusColor(_ status: HealthCheckStatus) -> Color {
        switch status { case .passed: return .green; case .warning: return .orange; case .failed: return .red }
    }
}

private struct HealthShareFile: Identifiable {
    let url: URL
    var id: String { url.path }
}
