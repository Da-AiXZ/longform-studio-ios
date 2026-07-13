import SwiftUI

struct ProjectWorkspaceView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject var session: ProjectSession
    @StateObject private var workflow = AIWorkflowController()
    @State private var selectedTab = WorkspaceTab.writing
    @State private var showSettings = false
    @State private var showExport = false

    init(session: ProjectSession) {
        _session = StateObject(wrappedValue: session)
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
            Group {
                switch selectedTab {
                case .writing: WritingView(session: session, workflow: workflow)
                case .planning: PlanningView(session: session, workflow: workflow)
                case .reference: ReferenceView(session: session)
                case .quality: QualityView(session: session, workflow: workflow)
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
                    Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("设置")
                }
            }
            .safeAreaInset(edge: .bottom) { tabBar }
        }
        .environmentObject(session)
        .environmentObject(workflow)
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView() }
                .environmentObject(session.settings)
        }
        .sheet(isPresented: $showExport) { ExportView(session: session) }
        .alert("保存失败", isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })) {
            Button("好", role: .cancel) { session.errorMessage = nil }
        } message: {
            Text(session.errorMessage ?? "未知错误")
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active { workflow.cancel() }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(WorkspaceTab.allCases, id: \.self) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 17, weight: selectedTab == tab ? .semibold : .regular))
                        Text(tab.rawValue).font(.caption2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(selectedTab == tab ? Color.accentColor : .secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .background(.bar)
    }

    private func close() {
        workflow.cancel()
        Task {
            await session.flushSave()
            dismiss()
        }
    }
}
