import SwiftUI
import NovelCore

struct ProjectWorkspaceView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject var session: ProjectSession
    @StateObject private var workflow: AIWorkflowController
    @StateObject private var agent: WritingAgentController
    @State private var selectedTab = WorkspaceTab.writing
    @State private var showSettings = false
    @State private var showExport = false
    @State private var showTemplates = false
    @State private var showHealthCheck = false

    init(session: ProjectSession) {
        let executor = WorkflowToolExecutor()
        _session = StateObject(wrappedValue: session)
        _workflow = StateObject(wrappedValue: AIWorkflowController(executor: executor))
        _agent = StateObject(wrappedValue: WritingAgentController(session: session, executor: executor))
    }

    enum WorkspaceTab: String, CaseIterable {
        case writing = "写作"
        case planning = "规划"
        case reference = "资料"
        case quality = "质检"

        var icon: String {
            switch self {
            case .writing: return "square.and.pencil"
            case .planning: return "list.bullet.rectangle"
            case .reference: return "person.2.crop.square.stack"
            case .quality: return "checkmark.seal"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("工作模式", selection: Binding(
                    get: { session.workspace.preferredMode },
                    set: { session.setWorkspaceMode($0) }
                )) {
                    Label("AI 模式", systemImage: "sparkles").tag(WorkspaceMode.agent)
                    Label("手动模式", systemImage: "slider.horizontal.3").tag(WorkspaceMode.manual)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                if session.workspace.preferredMode == .agent {
                    AgentWorkspaceView(
                        session: session,
                        agent: agent,
                        configureModel: { showSettings = true },
                        openTemplates: { showTemplates = true },
                        openHealthCheck: { showHealthCheck = true }
                    )
                } else {
                    manualWorkspace
                }
            }
            .navigationTitle(session.workspace.project.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { close() } label: { Image(systemName: "chevron.down") }
                        .accessibilityLabel("返回作品库")
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if session.isSaving { ProgressView().controlSize(.small) }
                    Button { showExport = true } label: { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("导出")
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("设置")
                }
            }
        }
        .environmentObject(session)
        .environmentObject(workflow)
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView() }.environmentObject(session.settings)
        }
        .sheet(isPresented: $showExport) { ExportView(session: session) }
        .sheet(isPresented: $showTemplates) {
            TemplateLibraryView(session: session, executor: workflow.executor).environmentObject(session.settings)
        }
        .sheet(isPresented: $showHealthCheck) {
            HealthReportView(session: session).environmentObject(session.settings)
        }
        .alert("保存失败", isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })) {
            Button("好", role: .cancel) { session.errorMessage = nil }
        } message: { Text(session.errorMessage ?? "未知错误") }
        .onChange(of: scenePhase) { phase in
            if phase != .active {
                Task {
                    await workflow.cancelAndWait()
                    await agent.pauseAndFlush()
                }
            }
        }
    }

    private var manualWorkspace: some View {
        Group {
            VStack(spacing: 0) {
                Group {
                    switch selectedTab {
                    case .writing: WritingView(session: session, workflow: workflow)
                    case .planning: PlanningView(session: session, workflow: workflow)
                    case .reference: ReferenceView(session: session)
                    case .quality: QualityView(session: session, workflow: workflow)
                    }
                }
                manualTabBar
            }
        }
    }

    private var manualTabBar: some View {
        HStack(spacing: 0) {
            ForEach(WorkspaceTab.allCases, id: \.self) { tab in
                Button { selectedTab = tab } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon).font(.system(size: 17, weight: selectedTab == tab ? .semibold : .regular))
                        Text(tab.rawValue).font(.caption2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .foregroundStyle(selectedTab == tab ? Color.accentColor : .secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .background(.bar)
    }

    private func close() {
        Task {
            await workflow.cancelAndWait()
            await agent.pauseAndFlush()
            dismiss()
        }
    }
}
