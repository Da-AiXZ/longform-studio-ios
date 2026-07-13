import SwiftUI
import UniformTypeIdentifiers
import NovelCore

struct TemplateLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: SettingsStore
    let session: ProjectSession?
    let executor: WorkflowToolExecutor
    @StateObject private var analysis: TemplateAnalysisController
    @State private var showImporter = false
    @State private var selectedTemplate: WritingTemplate?
    @State private var editingTemplate: WritingTemplate?

    init(session: ProjectSession? = nil, executor: WorkflowToolExecutor? = nil, indexStore: ManuscriptIndexStore = .live()) {
        self.session = session
        self.executor = executor ?? WorkflowToolExecutor()
        _analysis = StateObject(wrappedValue: TemplateAnalysisController(indexStore: indexStore))
    }

    var body: some View {
        NavigationStack {
            List {
                if let session, session.workspace.appliedTemplate != nil {
                    Section("当前作品") {
                        Button(role: .destructive) {
                            session.applyTemplate(nil)
                        } label: {
                            Label("不使用写作模板", systemImage: "xmark.circle")
                        }
                    }
                }
                analysisSection
                Section("模板 · \(settings.writingTemplates.count)") {
                    if settings.writingTemplates.isEmpty {
                        Text("暂无写作模板")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(settings.writingTemplates) { template in
                            Button { selectedTemplate = template } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(template.name).font(.headline).foregroundStyle(.primary)
                                        Spacer()
                                        Text("\(Int(template.confidence * 100))%")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(template.summary)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    settings.delete(templateID: template.id)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("写作模板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { showImporter = true } label: { Image(systemName: "doc.badge.plus") }
                        .accessibilityLabel("分析小说")
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.plainText, UTType(filenameExtension: "md") ?? .plainText], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                analysis.analyze(url: url, perspective: session?.workspace.project.perspective ?? .thirdPersonLimited)
            }
        }
        .sheet(item: $selectedTemplate) { template in
            TemplateDetailView(template: template, canApply: session != nil, isApplied: session?.workspace.appliedTemplate?.sourceTemplateID == template.id, edit: {
                selectedTemplate = nil
                editingTemplate = template
            }, duplicate: {
                var copy = template
                copy.id = UUID()
                copy.name += " 副本"
                copy.createdAt = Date()
                settings.save(template: copy)
                selectedTemplate = nil
            }) {
                session?.applyTemplate(template)
                selectedTemplate = nil
            }
        }
        .sheet(item: $editingTemplate) { template in
            TemplateEditorView(template: template) { updated in
                settings.save(template: updated)
                editingTemplate = nil
            }
        }
    }

    @ViewBuilder
    private var analysisSection: some View {
        Section {
            switch analysis.phase {
            case .idle:
                Button { showImporter = true } label: { Label("分析 TXT 或 Markdown", systemImage: "doc.text.magnifyingglass") }
            case .copying:
                HStack { ProgressView(); Text("正在准备受保护的临时文件") }
                Button("停止", role: .destructive) { analysis.cancel() }
            case .scanning:
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: analysis.progress.fractionCompleted)
                    Text("已扫描 \(ByteCountFormatter.string(fromByteCount: analysis.progress.processedBytes, countStyle: .file)) · \(analysis.progress.chaptersFound) 章")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("停止", role: .destructive) { analysis.cancel() }
            case .ready:
                analysisResult(showSynthesis: true)
            case .synthesizing:
                HStack { ProgressView(); Text("AI 正在提炼抽象写作策略") }
                Button("停止", role: .destructive) { analysis.cancel() }
            case .completed:
                analysisResult(showSynthesis: false)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Button("重新选择文件") { showImporter = true }
            }
        } header: {
            Text("长篇分析")
        } footer: {
            Text("全文仅在本机流式扫描；模板保存统计与抽象策略，不保存上传小说原文。")
        }
    }

    @ViewBuilder
    private func analysisResult(showSynthesis: Bool) -> some View {
        if let index = analysis.index, let template = analysis.template {
            LabeledContent("覆盖", value: "\(index.chapterMetrics.count) 章 · \(index.analyzedCharacters) 字")
            LabeledContent("AI 输入上限", value: "约 \(min(80_000, index.estimatedSynthesisTokens)) Token")
            Text(template.summary).font(.subheadline).foregroundStyle(.secondary)
            if showSynthesis, !settings.profiles.isEmpty {
                Button {
                    if let session {
                        analysis.synthesize(session: session, executor: executor)
                    } else {
                        analysis.synthesize(settings: settings, executor: executor)
                    }
                } label: {
                    Label("用 AI 补充语义策略", systemImage: "sparkles")
                }
            }
            Button {
                settings.save(template: template)
                analysis.markSaved()
            } label: {
                Label("保存到模板库", systemImage: "tray.and.arrow.down")
            }
            if session != nil {
                Button {
                    settings.save(template: template)
                    session?.applyTemplate(template)
                    analysis.markSaved()
                } label: {
                    Label("保存并用于当前作品", systemImage: "checkmark.circle")
                }
            }
            Button("分析其他文件") { analysis.reset(); showImporter = true }
        }
    }
}

private struct TemplateDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let template: WritingTemplate
    let canApply: Bool
    let isApplied: Bool
    let edit: () -> Void
    let duplicate: () -> Void
    let apply: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("概览") {
                    Text(template.summary)
                    LabeledContent("覆盖率", value: "\(Int(template.coverage * 100))%")
                    LabeledContent("置信度", value: "\(Int(template.confidence * 100))%")
                    LabeledContent("来源", value: template.sourceDescription)
                }
                strategySection("结构", values: template.structureStrategies)
                strategySection("节奏与爽点", values: template.pacingStrategies + template.payoffStrategies)
                strategySection("伏笔与钩子", values: template.foreshadowingStrategies + template.hookStrategies)
                strategySection("避免", values: template.avoidedPractices)
            }
            .navigationTitle(template.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Menu {
                        Button(action: edit) { Label("编辑", systemImage: "pencil") }
                        Button(action: duplicate) { Label("创建副本", systemImage: "plus.square.on.square") }
                    } label: { Image(systemName: "ellipsis.circle") }
                    if canApply {
                        Button(isApplied ? "已应用" : "应用", action: apply).disabled(isApplied)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func strategySection(_ title: String, values: [String]) -> some View {
        if !values.isEmpty {
            Section(title) { ForEach(values.indices, id: \.self) { Text(values[$0]) } }
        }
    }
}

private struct TemplateEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var value: WritingTemplate
    @State private var structureText: String
    @State private var pacingText: String
    @State private var payoffText: String
    @State private var foreshadowingText: String
    @State private var hookText: String
    @State private var recommendedText: String
    @State private var avoidedText: String
    let save: (WritingTemplate) -> Void

    init(template: WritingTemplate, save: @escaping (WritingTemplate) -> Void) {
        _value = State(initialValue: template)
        _structureText = State(initialValue: template.structureStrategies.joined(separator: "\n"))
        _pacingText = State(initialValue: template.pacingStrategies.joined(separator: "\n"))
        _payoffText = State(initialValue: template.payoffStrategies.joined(separator: "\n"))
        _foreshadowingText = State(initialValue: template.foreshadowingStrategies.joined(separator: "\n"))
        _hookText = State(initialValue: template.hookStrategies.joined(separator: "\n"))
        _recommendedText = State(initialValue: template.recommendedPractices.joined(separator: "\n"))
        _avoidedText = State(initialValue: template.avoidedPractices.joined(separator: "\n"))
        self.save = save
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("模板") {
                    TextField("名称", text: $value.name)
                    TextField("摘要", text: $value.summary, axis: .vertical).lineLimit(3...8)
                }
                strategyField("结构策略", text: $structureText)
                strategyField("节奏策略", text: $pacingText)
                strategyField("爽点策略", text: $payoffText)
                strategyField("伏笔策略", text: $foreshadowingText)
                strategyField("钩子策略", text: $hookText)
                strategyField("推荐做法", text: $recommendedText)
                strategyField("避免做法", text: $avoidedText)
            }
            .navigationTitle("编辑模板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        value.structureStrategies = split(structureText)
                        value.pacingStrategies = split(pacingText)
                        value.payoffStrategies = split(payoffText)
                        value.foreshadowingStrategies = split(foreshadowingText)
                        value.hookStrategies = split(hookText)
                        value.recommendedPractices = split(recommendedText)
                        value.avoidedPractices = split(avoidedText)
                        save(value)
                        dismiss()
                    }
                    .disabled(value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func strategyField(_ title: String, text: Binding<String>) -> some View {
        Section(title) { TextField("每行一项", text: text, axis: .vertical).lineLimit(3...10) }
    }

    private func split(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
