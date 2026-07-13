import SwiftUI
import NovelCore

struct VersionHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: ProjectSession
    let chapter: ChapterCard
    @State private var comparison: ChapterVersion?

    var body: some View {
        NavigationStack {
            List {
                ForEach(session.versions(for: chapter)) { version in
                    Button { comparison = version } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(sourceName(version.source)).font(.headline)
                                if version.id == session.selectedChapter?.activeVersionID {
                                    Text("当前").font(.caption.weight(.semibold)).foregroundStyle(.tint)
                                }
                                if version.approvedAt != nil {
                                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                                }
                                Spacer()
                                Text(version.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                            if !version.note.isEmpty { Text(version.note).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                            Text("\(version.characterCount) 字")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle("版本历史")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
        }
        .task { await session.loadVersions(for: chapter) }
        .sheet(item: $comparison) { version in
            VersionComparisonView(session: session, chapter: chapter, candidateID: version.id)
        }
    }

    private func sourceName(_ source: VersionSource) -> String {
        switch source {
        case .manual: return "人工版本"
        case .generated: return "AI 候选"
        case .rewritten: return "修订候选"
        case .imported: return "导入版本"
        }
    }
}

private struct VersionComparisonView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: ProjectSession
    let chapter: ChapterCard
    let candidateID: UUID

    private var candidate: ChapterVersion? { session.versions(for: chapter).first { $0.id == candidateID } }
    private var currentBody: String { session.activeVersion(for: chapter)?.body ?? "" }
    private var entries: [ParagraphDiffEntry] { ParagraphDiff.compare(old: currentBody, new: candidate?.body ?? "") }

    var body: some View {
        NavigationStack {
            Group {
                if candidate?.isBodyLoaded == true && session.isActiveBodyLoaded(for: chapter) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(entries) { entry in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: icon(entry.kind))
                                        .font(.caption)
                                        .foregroundStyle(color(entry.kind))
                                        .frame(width: 18)
                                    Text(entry.text)
                                        .font(.body)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(12)
                                .background(color(entry.kind).opacity(entry.kind == .unchanged ? 0 : 0.08))
                                Divider()
                            }
                        }
                    }
                } else {
                    ProgressView("正在加载版本")
                }
            }
            .navigationTitle("段落差异")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("采用此版本") {
                        session.acceptVersion(chapterID: chapter.id, versionID: candidateID)
                        dismiss()
                    }
                    .disabled(candidateID == chapter.activeVersionID)
                }
            }
        }
        .task { await session.loadVersions(for: chapter) }
    }

    private func icon(_ kind: ParagraphDiffKind) -> String {
        switch kind {
        case .unchanged: return "equal"
        case .inserted: return "plus"
        case .deleted: return "minus"
        }
    }

    private func color(_ kind: ParagraphDiffKind) -> Color {
        switch kind {
        case .unchanged: return .secondary
        case .inserted: return .green
        case .deleted: return .red
        }
    }
}
