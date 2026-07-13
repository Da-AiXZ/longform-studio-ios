import SwiftUI
import NovelCore

struct ChapterAIView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: ProjectSession
    @ObservedObject var workflow: AIWorkflowController
    let chapter: ChapterCard
    @State private var showPlanningResult = false
    @State private var selectedCandidate: ChapterVersion?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    WorkflowStatusView(workflow: workflow)
                        .listRowInsets(EdgeInsets())
                }

                Section("准备") {
                    Button { workflow.generateChapterOutlineOptions(session: session, chapter: chapter) } label: {
                        Label("生成两个章纲方案", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    Button { showPlanningResult = true } label: {
                        Label("查看最近策划结果", systemImage: "doc.text.magnifyingglass")
                    }
                    .disabled(workflow.planningResult.isEmpty)
                }

                Section("正文") {
                    Button { workflow.generateDraft(session: session, chapter: chapter) } label: {
                        Label("生成完整章节候选", systemImage: "sparkles.rectangle.stack")
                    }
                    Button { workflow.runFourReviews(session: session, chapter: chapter) } label: {
                        Label("运行四类审稿", systemImage: "checklist")
                    }
                    .disabled(!session.isActiveBodyLoaded(for: chapter) || session.activeVersion(for: chapter)?.body.isEmpty != false)
                    Button { workflow.extractCandidateFacts(session: session, chapter: chapter) } label: {
                        Label("提取候选连续性事实", systemImage: "tray.and.arrow.down")
                    }
                    .disabled(!session.isActiveBodyLoaded(for: chapter) || session.activeVersion(for: chapter)?.body.isEmpty != false)
                }

                if !workflow.streamedText.isEmpty {
                    Section("正在生成的候选") {
                        Text(workflow.streamedText)
                            .font(.subheadline)
                            .lineLimit(12)
                            .textSelection(.enabled)
                    }
                }

                let candidates = session.candidateVersions(for: chapter)
                if !candidates.isEmpty {
                    Section("候选版本 · \(candidates.count)") {
                        ForEach(candidates) { version in
                            Button { selectedCandidate = version } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(version.source == .rewritten ? "修订候选" : "生成候选")
                                        Spacer()
                                        Text("\(version.characterCount) 字")
                                            .font(.caption.monospacedDigit())
                                    }
                                    Text(version.note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("第 \(chapter.number) 章 AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
        }
        .task { await session.loadVersions(for: chapter) }
        .sheet(isPresented: $showPlanningResult) {
            NavigationStack {
                ScrollView {
                    Text(workflow.planningResult)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .textSelection(.enabled)
                }
                .navigationTitle("策划候选")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showPlanningResult = false } } }
            }
        }
        .sheet(item: $selectedCandidate) { candidate in
            CandidatePreviewView(session: session, chapter: chapter, candidateID: candidate.id)
        }
    }
}

private struct CandidatePreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: ProjectSession
    let chapter: ChapterCard
    let candidateID: UUID
    private var candidate: ChapterVersion? { session.versions(for: chapter).first { $0.id == candidateID } }

    var body: some View {
        NavigationStack {
            Group {
                if let candidate, candidate.isBodyLoaded {
                    ScrollView {
                        Text(candidate.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .textSelection(.enabled)
                    }
                } else {
                    ProgressView("正在加载候选")
                }
            }
            .navigationTitle("候选正文")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("采用") {
                        session.acceptVersion(chapterID: chapter.id, versionID: candidateID)
                        dismiss()
                    }
                }
            }
        }
        .task { await session.loadVersions(for: chapter) }
    }
}
