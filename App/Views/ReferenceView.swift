import SwiftUI
import UniformTypeIdentifiers
import NovelCore

struct ReferenceView: View {
    @ObservedObject var session: ProjectSession
    @State private var section = ReferenceSection.characters
    @State private var showCharacterEditor = false
    @State private var selectedCharacter: NovelCore.Character?
    @State private var showRuleEditor = false
    @State private var selectedRule: WorldRule?
    @State private var showTimelineEditor = false
    @State private var showForeshadowEditor = false
    @State private var showStyleImporter = false
    @State private var errorMessage: String?

    private enum ReferenceSection: String, CaseIterable {
        case characters = "人物"
        case rules = "规则"
        case timeline = "时间线"
        case foreshadowing = "伏笔"
        case facts = "事实"

        var icon: String {
            switch self {
            case .characters: return "person.2"
            case .rules: return "building.columns"
            case .timeline: return "calendar.day.timeline.leading"
            case .foreshadowing: return "point.topleft.down.to.point.bottomright.curvepath"
            case .facts: return "checkmark.square.stack"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("资料类型", selection: $section) {
                ForEach(ReferenceSection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            List {
                switch section {
                case .characters: charactersContent
                case .rules: rulesContent
                case .timeline: timelineContent
                case .foreshadowing: foreshadowingContent
                case .facts: factsContent
                }
            }
            .listStyle(.insetGrouped)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { showStyleImporter = true } label: { Label("导入自有样章校准", systemImage: "doc.text.magnifyingglass") }
                    Button { addCurrentSection() } label: { Label("添加\(section.rawValue)", systemImage: section.icon) }
                        .disabled(section == .facts)
                } label: {
                    Image(systemName: "plus.circle")
                }
                .accessibilityLabel("添加资料")
            }
        }
        .sheet(isPresented: $showCharacterEditor) { CharacterEditor(session: session, character: nil) }
        .sheet(item: $selectedCharacter) { CharacterEditor(session: session, character: $0) }
        .sheet(isPresented: $showRuleEditor) { WorldRuleEditor(session: session, rule: nil) }
        .sheet(item: $selectedRule) { WorldRuleEditor(session: session, rule: $0) }
        .sheet(isPresented: $showTimelineEditor) { TimelineEditor(session: session) }
        .sheet(isPresented: $showForeshadowEditor) { ForeshadowingEditor(session: session) }
        .fileImporter(isPresented: $showStyleImporter, allowedContentTypes: [.plainText, .markdown], allowsMultipleSelection: false) { result in
            importStyleSample(result)
        }
        .alert("导入失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "未知错误")
        }
    }

    @ViewBuilder
    private var charactersContent: some View {
        Section {
            if session.workspace.characters.isEmpty {
                EmptyReferenceRow(text: "人物表为空")
            } else {
                ForEach(session.workspace.characters) { character in
                    Button { selectedCharacter = character } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(character.name).font(.headline).foregroundStyle(.primary)
                                if !character.role.isEmpty { Text(character.role).font(.caption).foregroundStyle(.secondary) }
                            }
                            Text(character.currentState.isEmpty ? character.desire : character.currentState)
                                .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
            Button { showCharacterEditor = true } label: { Label("添加人物", systemImage: "plus") }
        } header: { Text("人物与当前状态") }
    }

    @ViewBuilder
    private var rulesContent: some View {
        Section {
            if session.workspace.worldRules.isEmpty {
                EmptyReferenceRow(text: "还没有世界或力量体系规则")
            } else {
                ForEach(session.workspace.worldRules) { rule in
                    Button { selectedRule = rule } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(rule.title).foregroundStyle(.primary)
                                Spacer()
                                Text(rule.category).font(.caption).foregroundStyle(.secondary)
                                if rule.immutable { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.orange) }
                            }
                            Text(rule.detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                }
            }
            Button { showRuleEditor = true } label: { Label("添加规则", systemImage: "plus") }
        } header: { Text("世界硬规则") }
    }

    @ViewBuilder
    private var timelineContent: some View {
        Section {
            if session.workspace.timeline.isEmpty {
                EmptyReferenceRow(text: "时间线为空")
            } else {
                ForEach(session.workspace.timeline.sorted { $0.order < $1.order }) { event in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(event.order)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(event.timeLabel).font(.caption).foregroundStyle(.secondary)
                            Text(event.event)
                        }
                    }
                }
            }
            Button { showTimelineEditor = true } label: { Label("添加事件", systemImage: "plus") }
        } header: { Text("正式时间线") }
    }

    @ViewBuilder
    private var foreshadowingContent: some View {
        Section {
            if session.workspace.foreshadowing.isEmpty {
                EmptyReferenceRow(text: "伏笔台账为空")
            } else {
                ForEach(session.workspace.foreshadowing) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Image(systemName: item.resolved ? "checkmark.circle.fill" : "circle.dashed")
                                .foregroundStyle(item.resolved ? .green : .orange)
                            Text(item.title).font(.headline)
                            Spacer()
                            if let chapter = item.payoffChapter { Text("预计 \(chapter) 章兑现").font(.caption).foregroundStyle(.secondary) }
                        }
                        Text(item.setup).font(.subheadline).foregroundStyle(.secondary)
                        if !item.intendedPayoff.isEmpty { Text("兑现：\(item.intendedPayoff)").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            Button { showForeshadowEditor = true } label: { Label("添加伏笔", systemImage: "plus") }
        } header: { Text("伏笔与兑现") }
    }

    @ViewBuilder
    private var factsContent: some View {
        Section {
            if session.workspace.facts.isEmpty {
                EmptyReferenceRow(text: "批准章节后，连续性事实会出现在这里")
            } else {
                ForEach(session.workspace.facts) { fact in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: factIcon(fact.status))
                            .foregroundStyle(factColor(fact.status))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(fact.subject) · \(fact.predicate)").font(.subheadline.weight(.semibold))
                            Text(fact.value)
                            if fact.conflictWithFactID != nil {
                                Text("与正式事实可能冲突").font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
        } header: { Text("连续性事实台账") }

        Section("文风校准") {
            if let style = session.workspace.styleProfile {
                LabeledContent("平均句长", value: "\(Int(style.averageSentenceLength)) 字")
                LabeledContent("对话比例", value: "\(Int(style.dialogueRatio * 100))%")
                LabeledContent("平均段长", value: "\(Int(style.paragraphLength)) 字")
                LabeledContent("来源", value: style.sourceDescription)
            } else {
                Text("尚未导入有权使用的自有样章。只会保存抽象风格指标，不保存样章正文。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button("导入自有样章") { showStyleImporter = true }
        }
    }

    private func addCurrentSection() {
        switch section {
        case .characters: showCharacterEditor = true
        case .rules: showRuleEditor = true
        case .timeline: showTimelineEditor = true
        case .foreshadowing: showForeshadowEditor = true
        case .facts: break
        }
    }

    private func importStyleSample(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            guard text.count >= 500 else { throw StyleImportError.sampleTooShort }
            var profile = TextAnalyzer.styleProfile(from: text, perspective: session.workspace.project.perspective)
            profile.sourceDescription = "自有样章：\(url.deletingPathExtension().lastPathComponent)（仅保存抽象指标）"
            session.updateStyleProfile(profile)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func factIcon(_ status: FactStatus) -> String {
        switch status {
        case .candidate: return "clock"
        case .accepted: return "checkmark.circle.fill"
        case .rejected: return "xmark.circle"
        }
    }

    private func factColor(_ status: FactStatus) -> Color {
        switch status {
        case .candidate: return .orange
        case .accepted: return .green
        case .rejected: return .secondary
        }
    }
}

private enum StyleImportError: LocalizedError {
    case sampleTooShort
    var errorDescription: String? { "样章至少需要 500 字，才能得到相对稳定的抽象风格指标。" }
}

private struct EmptyReferenceRow: View {
    let text: String
    var body: some View { Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 18) }
}

private struct CharacterEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: ProjectSession
    @State private var value: NovelCore.Character

    init(session: ProjectSession, character: NovelCore.Character?) {
        self.session = session
        _value = State(initialValue: character ?? NovelCore.Character(name: ""))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("身份") {
                    TextField("姓名", text: $value.name)
                    TextField("角色定位", text: $value.role)
                    TextField("说话口吻", text: $value.voice, axis: .vertical)
                }
                Section("内在驱动") {
                    TextField("欲望", text: $value.desire, axis: .vertical)
                    TextField("恐惧", text: $value.fear, axis: .vertical)
                    TextField("缺陷", text: $value.flaw, axis: .vertical)
                    TextField("人物弧线", text: $value.arc, axis: .vertical)
                }
                Section("当前正式状态") {
                    TextField("位置、伤势、关系、持有物等", text: $value.currentState, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .navigationTitle("人物")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { session.updateCharacter(value); dismiss() }.disabled(value.name.isEmpty) }
            }
        }
    }
}

private struct WorldRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: ProjectSession
    @State private var value: WorldRule

    init(session: ProjectSession, rule: WorldRule?) {
        self.session = session
        _value = State(initialValue: rule ?? WorldRule(category: "力量体系", title: "", detail: ""))
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("分类", text: $value.category)
                TextField("规则名", text: $value.title)
                TextField("规则详情", text: $value.detail, axis: .vertical).lineLimit(4...12)
                Toggle("不可被 AI 擅自改变", isOn: $value.immutable)
            }
            .navigationTitle("世界规则")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { session.updateWorldRule(value); dismiss() }.disabled(value.title.isEmpty || value.detail.isEmpty) }
            }
        }
    }
}

private struct TimelineEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: ProjectSession
    @State private var order: Int
    @State private var timeLabel = ""
    @State private var event = ""

    init(session: ProjectSession) {
        self.session = session
        _order = State(initialValue: (session.workspace.timeline.map(\.order).max() ?? 0) + 1)
    }

    var body: some View {
        NavigationStack {
            Form {
                Stepper("顺序：\(order)", value: $order, in: 1...99_999)
                TextField("时间标签", text: $timeLabel)
                TextField("明确发生的事件", text: $event, axis: .vertical).lineLimit(3...8)
            }
            .navigationTitle("时间线事件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { session.addTimelineEvent(TimelineEvent(order: order, timeLabel: timeLabel, event: event)); dismiss() }.disabled(timeLabel.isEmpty || event.isEmpty)
                }
            }
        }
    }
}

private struct ForeshadowingEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: ProjectSession
    @State private var title = ""
    @State private var setup = ""
    @State private var payoff = ""
    @State private var setupChapter = 1
    @State private var payoffChapter = 10

    var body: some View {
        NavigationStack {
            Form {
                TextField("伏笔名", text: $title)
                TextField("埋设内容", text: $setup, axis: .vertical)
                TextField("预期兑现", text: $payoff, axis: .vertical)
                Stepper("埋设章节：\(setupChapter)", value: $setupChapter, in: 1...99_999)
                Stepper("预计兑现章节：\(payoffChapter)", value: $payoffChapter, in: setupChapter...99_999)
            }
            .navigationTitle("伏笔")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        session.addForeshadowing(Foreshadowing(title: title, setup: setup, intendedPayoff: payoff, setupChapter: setupChapter, payoffChapter: payoffChapter))
                        dismiss()
                    }.disabled(title.isEmpty || setup.isEmpty)
                }
            }
        }
    }
}
