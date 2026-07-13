import SwiftUI
import NovelCore

struct AgentWorkspaceView: View {
    @ObservedObject var session: ProjectSession
    @ObservedObject var agent: WritingAgentController
    let configureModel: () -> Void
    let openTemplates: () -> Void
    let openHealthCheck: () -> Void

    @State private var input = ""
    @State private var showRunScope = false

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            conversation
            Divider()
            composer
        }
        .sheet(isPresented: $showRunScope) {
            RunScopePicker(agent: agent)
        }
    }

    private var controlBar: some View {
        HStack(spacing: 10) {
            Picker("执行策略", selection: Binding(
                get: { session.workspace.agentSession.policy },
                set: { agent.setPolicy($0) }
            )) {
                Text("监督").tag(AgentPolicy.supervised)
                Text("Pass").tag(AgentPolicy.pass)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 210)

            Spacer(minLength: 4)

            Menu {
                Button { showRunScope = true } label: { Label("开始执行", systemImage: "play.fill") }
                if agent.activeRun?.status == .paused {
                    Button { agent.resumeRun() } label: { Label("恢复任务", systemImage: "arrow.clockwise") }
                }
                if agent.activeRun != nil {
                    Button(role: .destructive) { agent.cancelRun() } label: { Label("取消任务", systemImage: "stop.fill") }
                }
                Divider()
                Button(action: openTemplates) { Label("写作模板", systemImage: "books.vertical") }
                Button(action: openHealthCheck) { Label("运行自检", systemImage: "stethoscope") }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Agent 工具")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if session.settings.profiles.isEmpty {
                        ModelSetupNotice(configureModel: configureModel)
                    }
                    if let run = agent.activeRun {
                        RunProgressView(run: run, pause: agent.pause, resume: agent.resumeRun)
                    }
                    ForEach(agent.messages) { message in
                        AgentMessageView(message: message)
                            .id(message.id)
                    }
                    ForEach(agent.pendingApprovals) { request in
                        ApprovalRequestView(request: request) {
                            agent.approve(request)
                        } revise: {
                            agent.requestRevision(request)
                        }
                        .id(request.id)
                    }
                    if !agent.streamedDraft.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("正在生成正文", systemImage: "text.cursor")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(agent.streamedDraft)
                                .font(.subheadline)
                                .lineLimit(10)
                        }
                        .padding(12)
                        .background(Color(uiColor: .secondarySystemBackground))
                    }
                    stateRow
                }
                .padding(12)
            }
            .onChange(of: agent.messages.count + agent.pendingApprovals.count) { _ in
                if let id = agent.pendingApprovals.last?.id ?? agent.messages.last?.id {
                    withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private var stateRow: some View {
        switch agent.state {
        case .thinking:
            HStack(spacing: 8) { ProgressView(); Text("正在整理你的想法") }
                .font(.subheadline).foregroundStyle(.secondary)
        case .running(let label):
            HStack(spacing: 8) { ProgressView(); Text(label) }
                .font(.subheadline).foregroundStyle(.secondary)
        case .waiting(let label):
            Label(label, systemImage: "person.crop.circle.badge.questionmark")
                .font(.subheadline).foregroundStyle(.orange)
        case .paused:
            Label("任务已暂停，可以从上一个安全步骤恢复", systemImage: "pause.circle")
                .font(.subheadline).foregroundStyle(.secondary)
        case .completed(let label):
            Label(label, systemImage: "checkmark.circle.fill")
                .font(.subheadline).foregroundStyle(.green)
        case .failed(let label):
            Label(label, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline).foregroundStyle(.red)
        case .idle:
            EmptyView()
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button(action: openTemplates) {
                Image(systemName: "paperclip")
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("上传小说并生成模板")
            TextField("聊设定、规划章节或提出修改", text: $input, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("agent-input")
            Button {
                let value = input
                input = ""
                agent.send(value)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.settings.profiles.isEmpty)
            .accessibilityLabel("发送")
            if agent.activeRun?.status == .running {
                Button { agent.pause() } label: { Image(systemName: "stop.circle") }
                    .font(.title2)
                    .foregroundStyle(.red)
                    .accessibilityLabel("停止并暂停")
            }
        }
        .padding(10)
        .background(.bar)
    }
}

private struct AgentMessageView: View {
    let message: AgentMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 44) }
            VStack(alignment: .leading, spacing: 5) {
                if message.kind != .text {
                    Label(kindTitle, systemImage: kindIcon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(message.content)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            if message.role != .user { Spacer(minLength: 34) }
        }
    }

    private var backgroundColor: Color {
        if message.role == .user { return Color.accentColor.opacity(0.16) }
        if message.kind == .report { return Color.red.opacity(0.1) }
        return Color(uiColor: .secondarySystemBackground)
    }
    private var kindTitle: String {
        switch message.kind { case .proposal: return "方案"; case .progress: return "进度"; case .approval: return "待确认"; case .report: return "报告"; case .text: return "" }
    }
    private var kindIcon: String {
        switch message.kind { case .proposal: return "doc.badge.gearshape"; case .progress: return "checklist"; case .approval: return "person.crop.circle.badge.questionmark"; case .report: return "exclamationmark.bubble"; case .text: return "bubble.left" }
    }
}

private struct ApprovalRequestView: View {
    let request: ApprovalRequest
    let approve: () -> Void
    let revise: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(request.title, systemImage: "person.crop.circle.badge.checkmark")
                .font(.headline)
            Text(request.summary)
                .font(.subheadline)
                .textSelection(.enabled)
            HStack {
                Button("要求修改", action: revise)
                    .buttonStyle(.bordered)
                Spacer()
                Button("确认", action: approve)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.45)))
    }
}

private struct RunProgressView: View {
    let run: AgentRun
    let pause: () -> Void
    let resume: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.scope.displayName).font(.subheadline.weight(.semibold))
                    Text("模型调用 \(run.modelCallsUsed)/\(run.maximumModelCalls)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if run.status == .running {
                    Button(action: pause) { Image(systemName: "pause.fill") }
                        .accessibilityLabel("暂停任务")
                } else if run.status == .paused {
                    Button(action: resume) { Image(systemName: "play.fill") }
                        .accessibilityLabel("恢复任务")
                }
            }
            ProgressView(value: Double(run.currentStepIndex), total: Double(max(1, run.steps.count)))
            if run.currentStepIndex < run.steps.count {
                Text(run.steps[run.currentStepIndex].title)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct ModelSetupNotice: View {
    let configureModel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("先连接你的 AI 模型", systemImage: "network.badge.shield.half.filled")
                .font(.headline)
            Text("添加一个兼容的 HTTPS 接口即可开始，所有 Agent 角色会默认使用该模型。")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("连接模型", action: configureModel)
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct RunScopePicker: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var agent: WritingAgentController
    @State private var selection = ScopeChoice.current
    @State private var count = 3

    private enum ScopeChoice: String, CaseIterable {
        case current = "当前章"
        case count = "连续若干章"
        case volume = "当前卷"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("执行范围") {
                    Picker("范围", selection: $selection) {
                        ForEach(ScopeChoice.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    if selection == .count {
                        Stepper("章节数：\(count)", value: $count, in: 1...20)
                    }
                }
                Section {
                    Text("默认只处理当前章。开始前会再次显示最大调用次数；达到范围、质量阻断或调用上限时自动停止。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("开始 Agent 任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("下一步") {
                        let scope: RunScope
                        switch selection {
                        case .current: scope = .currentChapter
                        case .count: scope = .chapterCount(count)
                        case .volume: scope = .currentVolume
                        }
                        agent.startRun(scope: scope)
                        dismiss()
                    }
                }
            }
        }
    }
}
