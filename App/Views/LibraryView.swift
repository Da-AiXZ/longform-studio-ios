import SwiftUI
import UniformTypeIdentifiers
import NovelCore

struct LibraryView: View {
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var settings: SettingsStore
    @State private var presentedSession: ProjectSession?
    @State private var showNewProject = false
    @State private var showImporter = false
    @State private var showSettings = false
    @State private var projectToDelete: NovelProject?

    var body: some View {
        NavigationStack {
            Group {
                if appStore.isLoading && appStore.projects.isEmpty {
                    ProgressView("正在读取作品")
                } else if appStore.projects.isEmpty {
                    emptyState
                } else {
                    projectList
                }
            }
            .navigationTitle("长篇工坊")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("设置")
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { showImporter = true } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .accessibilityLabel("导入作品")
                    Button { showNewProject = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("新建作品")
                }
            }
            .refreshable { await appStore.loadProjects() }
        }
        .sheet(isPresented: $showNewProject) {
            NewProjectView { session in
                presentedSession = session
                showNewProject = false
            }
            .environmentObject(appStore)
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView() }
                .environmentObject(settings)
        }
        .fullScreenCover(item: $presentedSession, onDismiss: {
            Task { await appStore.loadProjects() }
        }) { session in
            ProjectWorkspaceView(session: session)
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.plainText, .markdown, UTType(filenameExtension: "novelproj") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else {
                if case .failure(let error) = result { appStore.errorMessage = error.localizedDescription }
                return
            }
            Task { presentedSession = await appStore.importFile(url) }
        }
        .alert("操作失败", isPresented: Binding(get: { appStore.errorMessage != nil }, set: { if !$0 { appStore.errorMessage = nil } })) {
            Button("好", role: .cancel) { appStore.errorMessage = nil }
        } message: {
            Text(appStore.errorMessage ?? "未知错误")
        }
        .confirmationDialog("删除《\(projectToDelete?.title ?? "")》？", isPresented: Binding(get: { projectToDelete != nil }, set: { if !$0 { projectToDelete = nil } }), titleVisibility: .visible) {
            Button("删除作品和全部本地版本", role: .destructive) {
                guard let id = projectToDelete?.id else { return }
                Task { await appStore.deleteProject(id: id) }
                projectToDelete = nil
            }
            Button("取消", role: .cancel) { projectToDelete = nil }
        } message: {
            Text("此操作无法撤销。请先导出 .novelproj 备份。")
        }
    }

    private var projectList: some View {
        List {
            Section {
                ForEach(appStore.projects) { project in
                    Button {
                        Task { presentedSession = await appStore.openProject(id: project.id) }
                    } label: {
                        ProjectRow(project: project)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("project-\(project.id.uuidString)")
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { projectToDelete = project } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text("作品 · \(appStore.projects.count)")
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "books.vertical")
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                Text("还没有作品").font(.title3.weight(.semibold))
                Text("新建长篇工程，或导入 TXT、Markdown 与工程备份。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("新建作品") { showNewProject = true }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("create-first-project")
            Button("导入") { showImporter = true }
                .buttonStyle(.bordered)
        }
        .padding(28)
    }
}

private struct ProjectRow: View {
    let project: NovelProject

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(project.platform == .qidian ? Color(red: 0.15, green: 0.42, blue: 0.22) : Color(red: 0.76, green: 0.24, blue: 0.16))
                Image(systemName: "text.book.closed")
                    .font(.title2)
                    .foregroundStyle(.white)
            }
            .frame(width: 46, height: 58)

            VStack(alignment: .leading, spacing: 5) {
                Text(project.title)
                    .font(.headline)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(project.platform.displayName)
                    Text(project.genre)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(project.updatedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 5)
    }
}
