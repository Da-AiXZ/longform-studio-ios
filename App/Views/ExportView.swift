import SwiftUI

struct ExportView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: ProjectSession
    @State private var shareURL: URL?
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section("正文") {
                    ExportRow(title: "纯文本", detail: "按章节顺序导出当前版本", icon: "doc.plaintext") { prepareManuscript(markdown: false) }
                    ExportRow(title: "Markdown", detail: "章节标题使用一级标题", icon: "text.document") { prepareManuscript(markdown: true) }
                    if let chapter = session.selectedChapter {
                        ExportRow(title: "当前章节", detail: chapter.title, icon: "doc.text") { prepareManuscript(markdown: false, chapterID: chapter.id) }
                    }
                }
                Section("工程备份") {
                    ExportRow(title: "Novel Project", detail: "包含规划、版本、审稿与记录，不包含 API Key", icon: "shippingbox") { prepareArchive() }
                }
                Section {
                    let unresolved = session.workspace.reviews.flatMap(\.issues).filter { !$0.resolved }
                    if !unresolved.isEmpty {
                        Label("仍有 \(unresolved.count) 个未解决审稿问题", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    Text("投稿前请核对目标平台当前规则、内容标识要求与作品权利。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("导出")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                if isWorking { ToolbarItem(placement: .primaryAction) { ProgressView() } }
            }
        }
        .sheet(item: Binding(get: { shareURL.map(ShareFile.init) }, set: { shareURL = $0?.url })) { file in
            ShareSheet(items: [file.url])
        }
        .alert("导出失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "未知错误") }
    }

    private func prepareManuscript(markdown: Bool, chapterID: UUID? = nil) {
        isWorking = true
        Task {
            do { shareURL = try await session.exportManuscriptURL(markdown: markdown, chapterID: chapterID) }
            catch { errorMessage = error.localizedDescription }
            isWorking = false
        }
    }

    private func prepareArchive() {
        isWorking = true
        Task {
            do { shareURL = try await session.exportArchiveURL() }
            catch { errorMessage = error.localizedDescription }
            isWorking = false
        }
    }
}

private struct ExportRow: View {
    let title: String
    let detail: String
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 26).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct ShareFile: Identifiable {
    let url: URL
    var id: String { url.path }
}
