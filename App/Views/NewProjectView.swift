import SwiftUI
import NovelCore

struct NewProjectView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appStore: AppStore
    let onCreated: (ProjectSession) -> Void

    @State private var step = 0
    @State private var title = ""
    @State private var platform = PublishingPlatform.qidian
    @State private var genre = "玄幻"
    @State private var sellingPoint = ""
    @State private var targetWordCount = 1_000_000
    @State private var protagonistGoal = ""
    @State private var restrictedContent = ""
    @State private var perspective = NarrativePerspective.thirdPersonLimited
    @State private var targetChapterWords = 2_500
    @State private var isCreating = false

    var body: some View {
        NavigationStack {
            Form {
                if step == 0 { identitySection }
                else if step == 1 { storySection }
                else { formatSection }
            }
            .navigationTitle("新建作品")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { bottomBar }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .interactiveDismissDisabled(isCreating)
    }

    private var identitySection: some View {
        Group {
            Section("作品") {
                TextField("作品名", text: $title)
                    .accessibilityIdentifier("new-project-title")
                Picker("目标平台", selection: $platform) {
                    ForEach(PublishingPlatform.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                TextField("题材", text: $genre)
            }
            Section {
                Text(BuiltInPlatformProfiles.notice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var storySection: some View {
        Group {
            Section("创作核心") {
                TextField("一句话核心卖点", text: $sellingPoint, axis: .vertical)
                    .lineLimit(2...5)
                TextField("主角长期目标", text: $protagonistGoal, axis: .vertical)
                    .lineLimit(2...5)
            }
            Section("限制内容") {
                TextField("用逗号分隔禁用内容或词语", text: $restrictedContent, axis: .vertical)
                    .lineLimit(2...5)
            }
        }
    }

    private var formatSection: some View {
        Group {
            Section("篇幅") {
                Stepper("预计总字数：\(targetWordCount)", value: $targetWordCount, in: 50_000...5_000_000, step: 50_000)
                Stepper("每章目标：\(targetChapterWords) 字", value: $targetChapterWords, in: 1_000...8_000, step: 250)
            }
            Section("叙事") {
                Picker("叙事视角", selection: $perspective) {
                    ForEach(NarrativePerspective.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
            Section("确认") {
                LabeledContent("作品", value: title)
                LabeledContent("平台", value: platform.displayName)
                LabeledContent("题材", value: genre)
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if step > 0 {
                Button("上一步") { step -= 1 }
                    .buttonStyle(.bordered)
            }
            Button {
                if step < 2 { step += 1 } else { create() }
            } label: {
                if isCreating { ProgressView().frame(maxWidth: .infinity) }
                else { Text(step < 2 ? "下一步" : "创建作品").frame(maxWidth: .infinity) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canContinue || isCreating)
            .accessibilityIdentifier("new-project-next")
        }
        .padding()
        .background(.bar)
    }

    private var canContinue: Bool {
        switch step {
        case 0: return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !genre.isEmpty
        case 1: return !sellingPoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !protagonistGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: return true
        }
    }

    private func create() {
        isCreating = true
        let restrictions = restrictedContent
            .components(separatedBy: CharacterSet(charactersIn: ",，、\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let project = NovelProject(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            platform: platform,
            genre: genre,
            sellingPoint: sellingPoint,
            targetWordCount: targetWordCount,
            protagonistGoal: protagonistGoal,
            restrictedContent: restrictions,
            perspective: perspective,
            targetChapterWords: targetChapterWords
        )
        Task {
            if let session = await appStore.createProject(project) { onCreated(session) }
            isCreating = false
        }
    }
}
