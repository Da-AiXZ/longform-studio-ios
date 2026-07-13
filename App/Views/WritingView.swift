import SwiftUI
import NovelCore

struct WritingView: View {
    @ObservedObject var session: ProjectSession
    @ObservedObject var workflow: AIWorkflowController
    @State private var showChapterList = false
    @State private var showChapterCard = false
    @State private var showVersions = false
    @State private var showAI = false
    @State private var showSelectionRewrite = false
    @State private var showFind = false
    @State private var focusMode = false
    @State private var selectedRange = NSRange(location: 0, length: 0)
    @State private var editorText = ""
    @State private var editingChapterID: UUID?
    @State private var editingVersionID: UUID?
    @State private var searchText = ""
    @State private var replaceText = ""

    var body: some View {
        VStack(spacing: 0) {
            if focusMode {
                HStack {
                    Text(session.selectedChapter?.title ?? "正文").font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Button { focusMode = false } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                        .accessibilityLabel("退出专注模式")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            } else { chapterHeader }
            if showFind && !focusMode { findBar }
            Divider()
            if let chapter = session.selectedChapter {
                if session.isActiveBodyLoaded(for: chapter) {
                    LongTextEditor(
                        text: Binding(
                            get: { editorText },
                            set: { value in
                                editorText = value
                            }
                        ),
                        selectedRange: $selectedRange,
                        onCommit: { commitEditorText() }
                    )
                    .id(chapter.id)
                    .overlay(alignment: .bottomTrailing) {
                        Text("\(TextAnalyzer.statistics(for: editorText).chineseCharacterCount) 字")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(.thinMaterial, in: Capsule())
                            .padding(10)
                    }
                } else {
                    ProgressView("正在加载正文")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                noChapterState
            }
        }
        .onAppear { loadSelectedChapter() }
        .onChange(of: session.selectedChapterID) { _ in loadSelectedChapter() }
        .onDisappear { commitEditorText() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in commitEditorText() }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Button { NotificationCenter.default.post(name: LongTextEditor.undoNotification, object: nil) } label: { Image(systemName: "arrow.uturn.backward") }
                    .accessibilityLabel("撤销")
                Button { NotificationCenter.default.post(name: LongTextEditor.redoNotification, object: nil) } label: { Image(systemName: "arrow.uturn.forward") }
                    .accessibilityLabel("重做")
                Spacer()
                Button { hideKeyboard() } label: { Image(systemName: "keyboard.chevron.compact.down") }
            }
        }
        .sheet(isPresented: $showChapterList) { ChapterListView(session: session) }
        .sheet(isPresented: $showChapterCard) {
            if let chapter = session.selectedChapter { ChapterCardEditor(session: session, chapter: chapter) }
        }
        .sheet(isPresented: $showVersions, onDismiss: loadSelectedChapter) {
            if let chapter = session.selectedChapter { VersionHistoryView(session: session, chapter: chapter) }
        }
        .sheet(isPresented: $showAI, onDismiss: loadSelectedChapter) {
            if let chapter = session.selectedChapter { ChapterAIView(session: session, workflow: workflow, chapter: chapter) }
        }
        .sheet(isPresented: $showSelectionRewrite) {
            if let chapter = session.selectedChapter {
                SelectionRewriteView(session: session, workflow: workflow, chapter: chapter, range: selectedRange)
            }
        }
    }

    private var chapterHeader: some View {
        HStack(spacing: 6) {
            Button { showChapterList = true } label: {
                Label(session.selectedChapter?.title ?? "选择章节", systemImage: "list.bullet")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Menu {
                Button { showChapterCard = true } label: { Label("编辑章卡", systemImage: "rectangle.and.pencil.and.ellipsis") }
                Button { commitEditorText(); showVersions = true } label: { Label("版本历史", systemImage: "clock.arrow.circlepath") }
                Button { showSelectionRewrite = true } label: { Label("改写选段", systemImage: "wand.and.stars") }
                    .disabled(selectedRange.length == 0 || !(session.selectedChapter.map { session.isActiveBodyLoaded(for: $0) } ?? false))
                Button { showFind.toggle() } label: { Label("查找替换", systemImage: "magnifyingglass") }
                Button { focusMode = true } label: { Label("专注模式", systemImage: "arrow.up.left.and.arrow.down.right") }
            } label: {
                Image(systemName: "ellipsis.circle").frame(width: 36, height: 36)
            }
            .accessibilityLabel("章节工具")

            Button { commitEditorText(); showAI = true } label: {
                Label("AI", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(session.selectedChapter == nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .topTrailing) {
            if focusMode {
                Button { focusMode = false } label: { Image(systemName: "xmark.circle.fill") }
            }
        }
    }

    private var findBar: some View {
        VStack(spacing: 7) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("查找", text: $searchText)
                Button { findNext() } label: { Image(systemName: "arrow.down") }
                    .disabled(searchText.isEmpty)
                Button { showFind = false } label: { Image(systemName: "xmark") }
            }
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
                TextField("替换为", text: $replaceText)
                Button("替换") { replaceSelection() }
                    .disabled(searchText.isEmpty)
                Button("全部") { replaceAll() }
                    .disabled(searchText.isEmpty)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var noChapterState: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.badge.plus")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("先创建第一章").font(.headline)
            Button("添加章节") { session.addChapter() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadSelectedChapter() {
        commitEditorText()
        guard let chapter = session.selectedChapter else {
            editorText = ""
            editingChapterID = nil
            editingVersionID = nil
            return
        }
        let targetID = chapter.id
        Task {
            await session.loadActiveBody(for: chapter)
            guard session.selectedChapterID == targetID || (session.selectedChapterID == nil && session.selectedChapter?.id == targetID) else { return }
            editorText = session.activeVersion(for: chapter)?.body ?? ""
            editingChapterID = targetID
            editingVersionID = session.activeVersion(for: chapter)?.id
            selectedRange = NSRange(location: 0, length: 0)
        }
    }

    private func findNext() {
        guard !searchText.isEmpty else { return }
        let source = editorText as NSString
        let start = min(selectedRange.location + selectedRange.length, source.length)
        var range = source.range(of: searchText, options: [], range: NSRange(location: start, length: source.length - start))
        if range.location == NSNotFound { range = source.range(of: searchText) }
        if range.location != NSNotFound { selectedRange = range }
    }

    private func replaceSelection() {
        guard let selected = editorText.substring(in: selectedRange), selected == searchText,
              let range = Range(selectedRange, in: editorText) else {
            findNext()
            return
        }
        editorText.replaceSubrange(range, with: replaceText)
        commitEditorText()
        selectedRange = NSRange(location: selectedRange.location, length: (replaceText as NSString).length)
    }

    private func replaceAll() {
        editorText = editorText.replacingOccurrences(of: searchText, with: replaceText)
        commitEditorText()
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func commitEditorText() {
        guard let editingChapterID, let editingVersionID,
              let chapter = session.workspace.chapters.first(where: { $0.id == editingChapterID }),
              session.isActiveBodyLoaded(for: chapter) else { return }
        self.editingVersionID = session.updateBody(chapterID: editingChapterID, versionID: editingVersionID, body: editorText)
    }
}

private struct SelectionRewriteView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: ProjectSession
    @ObservedObject var workflow: AIWorkflowController
    let chapter: ChapterCard
    let range: NSRange
    @State private var instruction = "增强冲突和画面感，保持事实与视角不变"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("改写要求", text: $instruction, axis: .vertical).lineLimit(3...8)
                } footer: {
                    Text("结果会保存为完整章节候选，不会覆盖当前正文。")
                }
                Section { WorkflowStatusView(workflow: workflow).listRowInsets(EdgeInsets()) }
            }
            .navigationTitle("改写选段")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("生成") { workflow.rewriteSelection(session: session, chapter: chapter, range: range, instruction: instruction) }
                        .disabled(instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct ChapterListView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: ProjectSession

    var body: some View {
        NavigationStack {
            List {
                ForEach(session.sortedChapters) { chapter in
                    Button {
                        session.selectedChapterID = chapter.id
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(chapter.title).foregroundStyle(.primary).lineLimit(2)
                                Text("第 \(chapter.number) 章 · \(statusText(chapter.status))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if chapter.id == session.selectedChapterID { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                }
            }
            .navigationTitle("章节")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button { session.addChapter() } label: { Image(systemName: "plus") } }
            }
        }
    }

    private func statusText(_ status: ChapterStatus) -> String {
        switch status {
        case .planned: return "规划中"
        case .drafting: return "写作中"
        case .reviewing: return "待审"
        case .approved: return "已批准"
        }
    }
}

private struct ChapterCardEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: ProjectSession
    let chapter: ChapterCard
    @State private var title: String
    @State private var goal: String
    @State private var conflict: String
    @State private var turn: String
    @State private var hook: String
    @State private var summary: String

    init(session: ProjectSession, chapter: ChapterCard) {
        self.session = session
        self.chapter = chapter
        _title = State(initialValue: chapter.title)
        _goal = State(initialValue: chapter.goal)
        _conflict = State(initialValue: chapter.conflict)
        _turn = State(initialValue: chapter.turn)
        _hook = State(initialValue: chapter.hook)
        _summary = State(initialValue: chapter.summary)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("章卡") {
                    TextField("标题", text: $title)
                    TextField("章节目标", text: $goal, axis: .vertical)
                    TextField("核心冲突", text: $conflict, axis: .vertical)
                    TextField("关键转折", text: $turn, axis: .vertical)
                    TextField("结尾钩子", text: $hook, axis: .vertical)
                }
                Section("批准后摘要") {
                    TextField("供后续章节检索的事实摘要", text: $summary, axis: .vertical)
                        .lineLimit(4...10)
                }
            }
            .navigationTitle("第 \(chapter.number) 章")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        session.updateChapterCard(id: chapter.id) { value in
                            value.title = title
                            value.goal = goal
                            value.conflict = conflict
                            value.turn = turn
                            value.hook = hook
                            value.summary = summary
                        }
                        dismiss()
                    }
                }
            }
        }
    }
}
