import SwiftUI
import NovelCore

struct PlanningView: View {
    @ObservedObject var session: ProjectSession
    @ObservedObject var workflow: AIWorkflowController
    @State private var showBible = false
    @State private var showVolumeEditor = false
    @State private var selectedVolume: VolumeOutline?
    @State private var showAIResult = false
    @State private var selectedArtifact: PlanningArtifact?

    var body: some View {
        List {
            Section {
                WorkflowStatusView(workflow: workflow).listRowInsets(EdgeInsets())
            }
            Section("策划流程") {
                Button { workflow.generateCreativeOptions(session: session) } label: {
                    Label("创意方案三选一", systemImage: "lightbulb.max")
                }
                Button { workflow.generateStoryBibleCandidate(session: session) } label: {
                    Label("生成故事圣经候选", systemImage: "book.pages")
                }
                Button { workflow.generateVolumeOutline(session: session) } label: {
                    Label("生成下一卷卷纲候选", systemImage: "rectangle.stack")
                }
                Button { showAIResult = true } label: {
                    Label("查看最近策划候选", systemImage: "doc.text")
                }
                .disabled(workflow.planningResult.isEmpty)
            }

            Section("策划候选记录") {
                if session.workspace.planningArtifacts.isEmpty {
                    Text("生成的策划候选会保存在这里。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(session.workspace.planningArtifacts.sorted { $0.createdAt > $1.createdAt }) { artifact in
                        Button { selectedArtifact = artifact } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(artifact.task.displayName).foregroundStyle(.primary)
                                    Text(artifact.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if artifact.selectedAt != nil {
                                    Label("已选", systemImage: "checkmark.circle.fill")
                                        .font(.caption).foregroundStyle(.green)
                                }
                            }
                        }
                    }
                }
            }

            Section("故事圣经") {
                PlanningSummaryRow(title: "核心前提", value: session.workspace.bible.premise)
                PlanningSummaryRow(title: "中央冲突", value: session.workspace.bible.centralConflict)
                PlanningSummaryRow(title: "终局承诺", value: session.workspace.bible.endingPromise)
                Button("编辑故事圣经") { showBible = true }
            }

            Section {
                if session.workspace.volumes.isEmpty {
                    Text("还没有卷纲").foregroundStyle(.secondary)
                } else {
                    ForEach(session.workspace.volumes.sorted { $0.number < $1.number }) { volume in
                        Button { selectedVolume = volume } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("第 \(volume.number) 卷 · \(volume.title)").foregroundStyle(.primary)
                                Text(volume.goal).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                }
                Button { showVolumeEditor = true } label: { Label("添加卷纲", systemImage: "plus") }
            } header: {
                Text("卷纲")
            }

            Section("章节规划") {
                ForEach(session.sortedChapters) { chapter in
                    Button { session.selectedChapterID = chapter.id } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(chapter.title).foregroundStyle(.primary)
                            Text(chapter.goal.isEmpty ? "未填写章节目标" : chapter.goal)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                Button { session.addChapter() } label: { Label("添加章节", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $showBible) { StoryBibleEditor(session: session) }
        .sheet(isPresented: $showVolumeEditor) { VolumeEditor(session: session, volume: nil) }
        .sheet(item: $selectedVolume) { VolumeEditor(session: session, volume: $0) }
        .sheet(isPresented: $showAIResult) {
            PlanningCandidateView(text: workflow.planningResult, selected: workflow.latestPlanningArtifactID.flatMap { id in session.workspace.planningArtifacts.first(where: { $0.id == id })?.selectedAt } != nil, onSelect: {
                if let id = workflow.latestPlanningArtifactID { session.selectPlanningArtifact(id: id) }
            }) { showAIResult = false }
        }
        .sheet(item: $selectedArtifact) { artifact in
            PlanningCandidateView(text: artifact.content, selected: artifact.selectedAt != nil, onSelect: {
                session.selectPlanningArtifact(id: artifact.id)
            }) { selectedArtifact = nil }
        }
    }
}

private struct PlanningSummaryRow: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.isEmpty ? "待填写" : value).foregroundStyle(value.isEmpty ? .secondary : .primary).lineLimit(3)
        }
    }
}

private struct StoryBibleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: ProjectSession
    @State private var bible: StoryBible
    @State private var themes: String
    @State private var forbidden: String

    init(session: ProjectSession) {
        self.session = session
        _bible = State(initialValue: session.workspace.bible)
        _themes = State(initialValue: session.workspace.bible.themes.joined(separator: "、"))
        _forbidden = State(initialValue: session.workspace.bible.forbiddenPatterns.joined(separator: "\n"))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("故事核心") {
                    TextField("核心前提", text: $bible.premise, axis: .vertical)
                    TextField("主题，用顿号分隔", text: $themes, axis: .vertical)
                    TextField("中央冲突", text: $bible.centralConflict, axis: .vertical)
                    TextField("终局承诺", text: $bible.endingPromise, axis: .vertical)
                }
                Section("创作边界") {
                    TextField("抽象文风规范", text: $bible.styleGuide, axis: .vertical)
                        .lineLimit(4...10)
                    TextField("禁用套路，每行一项", text: $forbidden, axis: .vertical)
                        .lineLimit(4...10)
                }
            }
            .navigationTitle("故事圣经")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        bible.themes = split(themes)
                        bible.forbiddenPatterns = split(forbidden)
                        session.updateBible(bible)
                        dismiss()
                    }
                }
            }
        }
    }

    private func split(_ value: String) -> [String] {
        value.components(separatedBy: CharacterSet(charactersIn: "、,，\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

private struct VolumeEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: ProjectSession
    @State private var value: VolumeOutline

    init(session: ProjectSession, volume: VolumeOutline?) {
        self.session = session
        let next = (session.workspace.volumes.map(\.number).max() ?? 0) + 1
        _value = State(initialValue: volume ?? VolumeOutline(number: next, title: ""))
    }

    var body: some View {
        NavigationStack {
            Form {
                Stepper("卷序：\(value.number)", value: $value.number, in: 1...999)
                TextField("卷名", text: $value.title)
                TextField("本卷目标", text: $value.goal, axis: .vertical)
                TextField("高潮", text: $value.climax, axis: .vertical)
                TextField("兑现与下一卷连接", text: $value.resolution, axis: .vertical)
            }
            .navigationTitle("卷纲")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { session.updateVolume(value); dismiss() }.disabled(value.title.isEmpty)
                }
            }
        }
    }
}

private struct PlanningCandidateView: View {
    let text: String
    let selected: Bool
    let onSelect: () -> Void
    let dismiss: () -> Void
    var body: some View {
        NavigationStack {
            ScrollView { Text(text).frame(maxWidth: .infinity, alignment: .leading).padding().textSelection(.enabled) }
                .navigationTitle("策划候选")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭", action: dismiss) }
                    ToolbarItem(placement: .confirmationAction) { Button(selected ? "已选" : "标记选中", action: onSelect).disabled(selected) }
                }
        }
    }
}
