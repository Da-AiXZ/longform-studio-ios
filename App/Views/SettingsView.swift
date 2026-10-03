import SwiftUI
import NovelCore

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: SettingsStore
    @State private var showNewProfile = false
    @State private var selectedProfile: AIEndpointProfile?
    @State private var selectedPlatform: PlatformProfile?
    @State private var showBlindTest = false
    @State private var showDiagnostics = false
    @State private var showHealthCheck = false

    var body: some View {
        List {
            Section {
                if settings.profiles.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("还没有模型配置").font(.headline)
                        Text("添加 OpenAI Chat Completions 兼容 HTTPS 接口后，才能使用策划、写作和审稿。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                } else {
                    ForEach(settings.profiles) { profile in
                        Button { selectedProfile = profile } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(profile.name).foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: profile.isSecure ? "lock.fill" : "lock.open.fill")
                                        .font(.caption).foregroundStyle(profile.isSecure ? .green : .red)
                                }
                                Text("\(profile.model) · \(profile.endpoint.host ?? profile.endpoint.absoluteString)")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                Button { showNewProfile = true } label: { Label("添加模型配置", systemImage: "plus") }
                    .accessibilityIdentifier("add-model-profile")
            } header: {
                Text("模型接口")
            } footer: {
                Text("API Key 仅存储在本机 Keychain，不写入工程备份或诊断日志。")
            }

            Section("高级设置") {
                DisclosureGroup("多模型角色分工") {
                    ForEach(AIRole.allCases, id: \.self) { role in
                        Picker(role.displayName, selection: Binding(
                            get: { settings.assignments.assignments[role] },
                            set: { value in
                                var assignments = settings.assignments
                                assignments.assignments[role] = value
                                settings.assignments = assignments
                            }
                        )) {
                            Text("使用第一个配置").tag(Optional<UUID>.none)
                            ForEach(settings.profiles) { profile in Text(profile.name).tag(Optional(profile.id)) }
                        }
                    }
                }
            }

            Section("质量基线") {
                ForEach(settings.platformProfiles) { profile in
                    Button { selectedPlatform = profile } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(profile.name).foregroundStyle(.primary)
                                Text("总分 \(Int(profile.minimumTotalScore)) · 单项 \(Int(profile.minimumDimensionScore))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                Text(BuiltInPlatformProfiles.notice).font(.footnote).foregroundStyle(.secondary)
            }

            Section("模型评测") {
                Button { showBlindTest = true } label: { Label("A/B 盲评", systemImage: "rectangle.split.2x1") }
                    .disabled(settings.profiles.count < 2)
                if settings.profiles.count < 2 {
                    Text("至少添加两个模型配置后可用。").font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section("本机") {
                Button { showHealthCheck = true } label: { Label("运行自检", systemImage: "checkmark.shield") }
                Button { showDiagnostics = true } label: { Label("脱敏诊断", systemImage: "stethoscope") }
                LabeledContent("最低系统", value: "iOS 16.0")
                LabeledContent("数据同步", value: "仅本机与手动备份")
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
        .sheet(isPresented: $showNewProfile) { ModelProfileEditor(profile: nil) }
        .sheet(item: $selectedProfile) { ModelProfileEditor(profile: $0) }
        .sheet(item: $selectedPlatform) { PlatformProfileEditor(profile: $0) }
        .sheet(isPresented: $showBlindTest) { BlindTestView() }
        .sheet(isPresented: $showDiagnostics) { DiagnosticView() }
        .sheet(isPresented: $showHealthCheck) {
            HealthReportView(session: nil).environmentObject(settings)
        }
    }
}

private struct ModelProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: SettingsStore
    @State private var profile: AIEndpointProfile
    @State private var endpointText: String
    @State private var apiKey = ""
    @State private var errorMessage: String?
    @State private var testMessage: String?
    @State private var isTesting = false
    private let existing: Bool

    init(profile: AIEndpointProfile?) {
        let value = profile ?? AIEndpointProfile(name: "", endpoint: URL(string: "https://api.example.com/v1/chat/completions")!, model: "")
        _profile = State(initialValue: value)
        _endpointText = State(initialValue: value.endpoint.absoluteString)
        existing = profile != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("接口") {
                    TextField("配置名称", text: $profile.name)
                    TextField("HTTPS Endpoint", text: $endpointText)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    TextField("模型名", text: $profile.model)
                        .textInputAutocapitalization(.never)
                    SecureField(existing ? "留空则保留现有 API Key" : "API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                }

                Section("认证") {
                    TextField("Header", text: $profile.authenticationHeader)
                        .textInputAutocapitalization(.never)
                    TextField("前缀", text: $profile.authenticationPrefix)
                        .textInputAutocapitalization(.never)
                }

                Section("生成参数") {
                    Stepper("上下文上限：\(profile.contextTokenLimit)", value: $profile.contextTokenLimit, in: 4_096...1_000_000, step: 4_096)
                    Stepper("输出上限：\(profile.outputTokenLimit)", value: $profile.outputTokenLimit, in: 512...64_000, step: 512)
                    VStack(alignment: .leading) {
                        Text("Temperature：\(profile.temperature, specifier: "%.2f")")
                        Slider(value: $profile.temperature, in: 0...2, step: 0.05)
                    }
                    Stepper("超时：\(Int(profile.timeoutSeconds)) 秒", value: $profile.timeoutSeconds, in: 15...600, step: 15)
                    Toggle("流式输出", isOn: $profile.streams)
                }

                Section {
                    Button { testConnection() } label: {
                        if isTesting { HStack { ProgressView(); Text("正在测试") } }
                        else { Label("测试连接", systemImage: "network") }
                    }
                    .disabled(!canSave || isTesting)
                    if let testMessage { Text(testMessage).font(.footnote).foregroundStyle(.secondary) }
                }

                if existing {
                    Section {
                        Button("删除配置", role: .destructive) {
                            do { try settings.delete(profile: profile); dismiss() }
                            catch { errorMessage = error.localizedDescription }
                        }
                    }
                }
            }
            .navigationTitle(existing ? "编辑模型" : "添加模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存", action: save).disabled(!canSave || isTesting) }
            }
        }
        .alert("操作失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "未知错误") }
    }

    private var canSave: Bool {
        guard let url = URL(string: endpointText), url.scheme?.lowercased() == "https" else { return false }
        return !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (existing || !apiKey.isEmpty)
    }

    private func normalizedProfile() -> AIEndpointProfile? {
        guard let url = URL(string: endpointText), url.scheme?.lowercased() == "https" else { return nil }
        var value = profile
        value.endpoint = url
        value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.model = value.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return value
    }

    private func save() {
        guard let value = normalizedProfile() else { return }
        if !existing {
            isTesting = true
            Task {
                do {
                    var testProfile = value
                    testProfile.outputTokenLimit = 16
                    testProfile.temperature = 0
                    _ = try await OpenAICompatibleClient().complete(profile: testProfile, apiKey: apiKey, messages: [ChatMessage(role: "user", content: "只回复 OK")])
                    try settings.save(profile: value, apiKey: apiKey)
                    dismiss()
                } catch {
                    errorMessage = error.localizedDescription
                    isTesting = false
                }
            }
            return
        }
        do {
            try settings.save(profile: value, apiKey: apiKey.isEmpty ? nil : apiKey)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }

    private func testConnection() {
        guard let value = normalizedProfile() else { return }
        isTesting = true
        testMessage = nil
        Task {
            do {
                let key = !apiKey.isEmpty ? apiKey : (try settings.keychain.value(for: value.keychainReference) ?? "")
                let result = try await OpenAICompatibleClient().complete(profile: value, apiKey: key, messages: [ChatMessage(role: "user", content: "只回复：连接成功")])
                testMessage = "接口返回：\(String(result.content.prefix(100)))"
            } catch { errorMessage = error.localizedDescription }
            isTesting = false
        }
    }
}

private struct PlatformProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: SettingsStore
    @State private var value: PlatformProfile

    init(profile: PlatformProfile) { _value = State(initialValue: profile) }

    var body: some View {
        NavigationStack {
            Form {
                Section("门槛") {
                    Stepper("综合分：\(Int(value.minimumTotalScore))", value: $value.minimumTotalScore, in: 50...100, step: 1)
                    Stepper("单项分：\(Int(value.minimumDimensionScore))", value: $value.minimumDimensionScore, in: 50...100, step: 1)
                }
                Section("评分权重") {
                    ForEach(value.weights.keys.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { dimension in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(dimension.displayName)
                                Spacer()
                                Text("\(Int((value.weights[dimension] ?? 0) * 100))%")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Slider(value: Binding(
                                get: { value.weights[dimension] ?? 0 },
                                set: { value.weights[dimension] = $0 }
                            ), in: 0.01...0.5, step: 0.01)
                        }
                    }
                }
                Section { Text("保存时会将全部权重归一化为 100%。这些是创作质检基线，不代表平台官方规则。") .font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle(value.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
            }
        }
    }

    private func save() {
        let total = value.weights.values.reduce(0, +)
        guard total > 0 else { return }
        value.weights = value.weights.mapValues { $0 / total }
        value.updatedAt = Date()
        if let index = settings.platformProfiles.firstIndex(where: { $0.id == value.id }) {
            settings.platformProfiles[index] = value
        }
        dismiss()
    }
}

private struct BlindTestView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: SettingsStore
    @State private var firstID: UUID?
    @State private var secondID: UUID?
    @State private var prompt = "为一部男频长篇提出一个开篇冲突，并写出约500字样章。"
    @State private var leftText = ""
    @State private var rightText = ""
    @State private var leftProfileID: UUID?
    @State private var rightProfileID: UUID?
    @State private var isRunning = false
    @State private var revealed = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("参评模型") {
                    Picker("模型 A", selection: $firstID) { profileOptions }
                    Picker("模型 B", selection: $secondID) { profileOptions }
                }
                Section("同一任务") {
                    TextField("评测提示", text: $prompt, axis: .vertical).lineLimit(4...10)
                    Button { runTest() } label: {
                        if isRunning { HStack { ProgressView(); Text("并行生成") } }
                        else { Label("开始盲评", systemImage: "play.fill") }
                    }
                    .disabled(!canRun || isRunning)
                }
                if !leftText.isEmpty || !rightText.isEmpty {
                    Section("结果 1") {
                        Text(leftText).lineLimit(20).textSelection(.enabled)
                        Button("选择结果 1") { choose(leftProfileID) }.disabled(revealed)
                    }
                    Section("结果 2") {
                        Text(rightText).lineLimit(20).textSelection(.enabled)
                        Button("选择结果 2") { choose(rightProfileID) }.disabled(revealed)
                    }
                    if revealed {
                        Section("身份揭晓") {
                            LabeledContent("结果 1", value: profileName(leftProfileID))
                            LabeledContent("结果 2", value: profileName(rightProfileID))
                        }
                    }
                }
            }
            .navigationTitle("A/B 盲评")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
        }
        .onAppear {
            firstID = settings.profiles.first?.id
            secondID = settings.profiles.dropFirst().first?.id
        }
        .alert("评测失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "未知错误") }
    }

    @ViewBuilder private var profileOptions: some View {
        Text("请选择").tag(Optional<UUID>.none)
        ForEach(settings.profiles) { Text($0.name).tag(Optional($0.id)) }
    }

    private var canRun: Bool { firstID != nil && secondID != nil && firstID != secondID && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func runTest() {
        guard let first = settings.profiles.first(where: { $0.id == firstID }), let second = settings.profiles.first(where: { $0.id == secondID }) else { return }
        isRunning = true
        revealed = false
        leftText = ""
        rightText = ""
        Task {
            do {
                let key1 = try settings.keychain.value(for: first.keychainReference) ?? ""
                let key2 = try settings.keychain.value(for: second.keychainReference) ?? ""
                async let output1 = OpenAICompatibleClient().complete(profile: first, apiKey: key1, messages: [ChatMessage(role: "user", content: prompt)])
                async let output2 = OpenAICompatibleClient().complete(profile: second, apiKey: key2, messages: [ChatMessage(role: "user", content: prompt)])
                let results = try await (output1, output2)
                if Bool.random() {
                    leftText = results.0.content; leftProfileID = first.id
                    rightText = results.1.content; rightProfileID = second.id
                } else {
                    leftText = results.1.content; leftProfileID = second.id
                    rightText = results.0.content; rightProfileID = first.id
                }
            } catch { errorMessage = error.localizedDescription }
            isRunning = false
        }
    }

    private func choose(_ id: UUID?) {
        guard let id else { return }
        settings.blindPreferences[id.uuidString, default: 0] += 1
        revealed = true
    }

    private func profileName(_ id: UUID?) -> String { settings.profiles.first { $0.id == id }?.name ?? "未知" }
}

private struct DiagnosticView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [DiagnosticEntry] = []
    @State private var shareURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if entries.isEmpty {
                    Text("暂无诊断记录。应用不上传遥测或崩溃数据。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(entries.reversed()) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.category).font(.caption.weight(.semibold))
                                Spacer()
                                Text(entry.timestamp, style: .time).font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(entry.message).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("脱敏诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button { export() } label: { Image(systemName: "square.and.arrow.up") } }
            }
        }
        .task { entries = await DiagnosticLogger.shared.allEntries() }
        .sheet(item: Binding(get: { shareURL.map(ShareDiagnostic.init) }, set: { shareURL = $0?.url })) { ShareSheet(items: [$0.url]) }
        .alert("导出失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "未知错误") }
    }

    private func export() {
        Task {
            do {
                let data = try await DiagnosticLogger.shared.exportData()
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("LongformStudio-Diagnostics.json")
                try data.write(to: url, options: [.atomic, .completeFileProtection])
                shareURL = url
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct ShareDiagnostic: Identifiable {
    let url: URL
    var id: String { url.path }
}
