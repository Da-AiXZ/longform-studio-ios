import SwiftUI
import NovelCore

struct NewProjectView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appStore: AppStore
    let onCreated: (ProjectSession) -> Void

    @State private var title = ""
    @State private var isCreating = false

    var body: some View {
        NavigationStack {
            Form {
                Section("作品") {
                    TextField("作品名", text: $title)
                        .accessibilityIdentifier("new-project-title")
                }
                Section {
                    Text("创建后直接和写作 Agent 聊想法。题材、平台、主角、篇幅和故事设定会在对话中逐步确认。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("新建作品")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button {
                    create()
                } label: {
                    if isCreating {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Label("创建并开始", systemImage: "arrow.right")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreating)
                .accessibilityIdentifier("new-project-next")
                .padding()
                .background(.bar)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
        .interactiveDismissDisabled(isCreating)
    }

    private func create() {
        isCreating = true
        let project = NovelProject(
            schemaVersion: ProjectRepository.currentSchemaVersion,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            platform: .qidian,
            genre: "待确认",
            sellingPoint: "",
            targetWordCount: 1_000_000,
            protagonistGoal: ""
        )
        Task {
            if let session = await appStore.createProject(project) { onCreated(session) }
            isCreating = false
        }
    }
}
