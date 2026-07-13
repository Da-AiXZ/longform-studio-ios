import SwiftUI
import NovelCore

struct QualityView: View {
    @ObservedObject var session: ProjectSession
    @ObservedObject var workflow: AIWorkflowController
    @State private var selectedChapterID: UUID?
    @State private var selectedIssueIDs = Set<UUID>()
    @State private var showOverride = false
    @State private var overrideReason = ""
    @State private var gateResult: QualityGateResult?

    private var chapter: ChapterCard? {
        let id = selectedChapterID ?? session.selectedChapterID
        return session.workspace.chapters.first { $0.id == id } ?? session.sortedChapters.first
    }

    var body: some View {
        List {
            Section("跨章回归") {
                Button { workflow.runRegressionReview(session: session) } label: {
                    Label("审查最近十个已批准章节", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!session.workspace.chapters.contains { $0.status == .approved })
                ForEach(session.workspace.reviews.filter { $0.kind == .regression }.sorted { $0.createdAt > $1.createdAt }) { report in
                    DisclosureGroup {
                        Text(report.summary)
                        ForEach(report.issues) { issue in IssueRow(issue: issue, selected: false, selectable: false, action: nil) }
                    } label: {
                        Text("回归报告 · \(report.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
            }

            Section {
                Picker("质检章节", selection: Binding(
                    get: { chapter?.id },
                    set: { selectedChapterID = $0 }
                )) {
                    ForEach(session.sortedChapters) { item in
                        Text(item.title).tag(Optional(item.id))
                    }
                }
                .disabled(session.sortedChapters.isEmpty)
            }

            if let chapter {
                Section {
                    WorkflowStatusView(workflow: workflow).listRowInsets(EdgeInsets())
                }

                scoreSection(chapter)
                localSection(chapter)
                aiReviewSection(chapter)
                issueSection(chapter)
                candidateFactSection(chapter)
                approvalSection(chapter)
            } else {
                Section { Text("创建并写入章节后才能质检。\n").foregroundStyle(.secondary) }
            }
        }
        .sheet(isPresented: $showOverride) {
            OverrideApprovalView(reason: $overrideReason) {
                guard let chapter else { return }
                gateResult = session.approveChapter(chapterID: chapter.id, manualOverrideReason: overrideReason)
                showOverride = false
            }
        }
        .task(id: chapter?.id) {
            if let chapter { await session.loadActiveBody(for: chapter) }
        }
        .alert("质量门禁", isPresented: Binding(get: { gateResult != nil }, set: { if !$0 { gateResult = nil } })) {
            Button("好", role: .cancel) { gateResult = nil }
        } message: {
            Text(gateMessage(gateResult))
        }
    }

    @ViewBuilder
    private func scoreSection(_ chapter: ChapterCard) -> some View {
        let profile = session.settings.platformProfile(for: session.workspace.project.platform)
        let result = session.qualityGateResult(for: chapter)
        Section("质量门禁") {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("综合分").font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "%.1f", result.totalScore))
                        .font(.system(.title2, design: .rounded).weight(.semibold))
                        .foregroundStyle(result.totalScore >= profile.minimumTotalScore ? .green : .orange)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(profile.name).font(.caption).foregroundStyle(.secondary)
                    Label(chapter.status == .approved ? "已批准" : (result.passed ? "可批准" : "未通过"), systemImage: chapter.status == .approved ? "checkmark.seal.fill" : (result.passed ? "checkmark.circle" : "xmark.circle"))
                        .foregroundStyle(chapter.status == .approved || result.passed ? .green : .red)
                }
            }
            Text("自动通过要求：总分 ≥ \(Int(profile.minimumTotalScore))、每项 ≥ \(Int(profile.minimumDimensionScore))，且无未解决的高等级问题。")
                .font(.footnote).foregroundStyle(.secondary)
            if !result.missingDimensions.isEmpty {
                Text("缺少评分：\(result.missingDimensions.map(\.displayName).joined(separator: "、"))")
                    .font(.footnote).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func localSection(_ chapter: ChapterCard) -> some View {
        let issues = session.localIssues(for: chapter)
        Section("本地扫描 · \(issues.count)") {
            if issues.isEmpty {
                Label("未发现机械性问题", systemImage: "checkmark.circle").foregroundStyle(.green)
            } else {
                ForEach(issues) { issue in IssueRow(issue: issue, selected: false, selectable: false, action: nil) }
            }
        }
    }

    @ViewBuilder
    private func aiReviewSection(_ chapter: ChapterCard) -> some View {
        let reports = session.reviews(for: chapter)
        Section("独立 AI 审稿") {
            Button { workflow.runFourReviews(session: session, chapter: chapter) } label: {
                Label("运行四类审稿", systemImage: "checklist")
            }
            .disabled(!session.isActiveBodyLoaded(for: chapter) || session.activeVersion(for: chapter)?.body.isEmpty != false)
            ForEach(reports) { report in
                DisclosureGroup {
                    Text(report.summary).font(.subheadline).foregroundStyle(.secondary)
                    ForEach(report.scores.keys.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { dimension in
                        LabeledContent(dimension.displayName, value: String(format: "%.0f", report.scores[dimension] ?? 0))
                    }
                } label: {
                    HStack {
                        Text(report.kind.displayName)
                        Spacer()
                        Text(report.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func issueSection(_ chapter: ChapterCard) -> some View {
        let reports = session.reviews(for: chapter)
        let unresolved = reports.flatMap { report in report.issues.map { ReportIssuePair(reportID: report.id, issue: $0) } }.filter { !$0.issue.resolved }
        Section("待修问题 · \(unresolved.count)") {
            if unresolved.isEmpty {
                Text("没有未解决的 AI 审稿问题。").foregroundStyle(.secondary)
            } else {
                ForEach(unresolved) { pair in
                    IssueRow(issue: pair.issue, selected: selectedIssueIDs.contains(pair.issue.id), selectable: true) {
                        if selectedIssueIDs.contains(pair.issue.id) { selectedIssueIDs.remove(pair.issue.id) }
                        else { selectedIssueIDs.insert(pair.issue.id) }
                    }
                    .swipeActions {
                        Button {
                            session.resolveIssue(reportID: pair.reportID, issueID: pair.issue.id, resolved: true)
                            selectedIssueIDs.remove(pair.issue.id)
                        } label: { Label("解决", systemImage: "checkmark") }
                        .tint(.green)
                    }
                }
                Button { workflow.rewrite(session: session, chapter: chapter, issueIDs: selectedIssueIDs) } label: {
                    Label("按已选问题生成修订候选", systemImage: "wand.and.stars")
                }
                .disabled(selectedIssueIDs.isEmpty)
            }
        }
    }

    @ViewBuilder
    private func candidateFactSection(_ chapter: ChapterCard) -> some View {
        let candidates = session.workspace.facts.filter { $0.chapterID == chapter.id && $0.status == .candidate }
        Section("候选事实 · \(candidates.count)") {
            Button { workflow.extractCandidateFacts(session: session, chapter: chapter) } label: {
                Label("从当前正文提取", systemImage: "tray.and.arrow.down")
            }
            .disabled(!session.isActiveBodyLoaded(for: chapter) || session.activeVersion(for: chapter)?.body.isEmpty != false)
            ForEach(candidates) { fact in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(fact.subject) · \(fact.predicate)").font(.subheadline.weight(.semibold))
                    Text(fact.value)
                    if fact.conflictWithFactID != nil {
                        Label("存在正式事实冲突，批准时会拒绝入账", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
            }
            Text("候选事实不会参与后续上下文，只有章节批准后才进入正式台账。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func approvalSection(_ chapter: ChapterCard) -> some View {
        Section("人工定稿") {
            Button {
                gateResult = session.approveChapter(chapterID: chapter.id)
            } label: {
                Label("通过质量门禁并批准", systemImage: "checkmark.seal")
            }
            .disabled(chapter.status == .approved || !session.isActiveBodyLoaded(for: chapter))
            Button { showOverride = true } label: {
                Label("填写理由后人工覆盖", systemImage: "person.badge.key")
            }
            .disabled(chapter.status == .approved || !session.isActiveBodyLoaded(for: chapter))
            if chapter.status == .approved {
                Text("此版本已定稿。继续编辑会自动派生新的人工版本，不会修改已批准版本。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func gateMessage(_ result: QualityGateResult?) -> String {
        guard let result else { return "" }
        if result.passed {
            return result.overrideReason == nil ? "章节已批准，候选事实已按冲突结果写入台账。" : "章节已通过人工覆盖批准，理由已保留。"
        }
        var parts = ["综合分：\(String(format: "%.1f", result.totalScore))。"]
        if !result.missingDimensions.isEmpty { parts.append("缺少评分：\(result.missingDimensions.map(\.displayName).joined(separator: "、"))。") }
        if !result.belowThreshold.isEmpty { parts.append("低于单项门槛：\(result.belowThreshold.map(\.displayName).joined(separator: "、"))。") }
        if !result.blockingIssues.isEmpty { parts.append("还有 \(result.blockingIssues.count) 个高等级问题。") }
        return parts.joined()
    }
}

private struct ReportIssuePair: Identifiable {
    var reportID: UUID
    var issue: ReviewIssue
    var id: UUID { issue.id }
}

private struct IssueRow: View {
    let issue: ReviewIssue
    let selected: Bool
    let selectable: Bool
    let action: (() -> Void)?

    var body: some View {
        Button { action?() } label: {
            HStack(alignment: .top, spacing: 10) {
                if selectable {
                    Image(systemName: selected ? "checkmark.square.fill" : "square")
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                }
                Circle().fill(severityColor).frame(width: 8, height: 8).padding(.top, 6)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(issue.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Spacer()
                        Text(issue.dimension.displayName).font(.caption).foregroundStyle(.secondary)
                    }
                    if !issue.evidence.isEmpty { Text(issue.evidence).font(.caption).foregroundStyle(.secondary).lineLimit(4) }
                    if !issue.suggestion.isEmpty { Text("建议：\(issue.suggestion)").font(.caption).foregroundStyle(.secondary).lineLimit(4) }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var severityColor: Color {
        switch issue.severity {
        case .info, .low: return .blue
        case .medium: return .orange
        case .high, .critical: return .red
        }
    }
}

private struct OverrideApprovalView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var reason: String
    let approve: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("说明为何可以保留未通过项", text: $reason, axis: .vertical)
                        .lineLimit(5...12)
                } footer: {
                    Text("人工覆盖会进入定稿记录，不会删除审稿问题。")
                }
            }
            .navigationTitle("人工覆盖")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("批准", action: approve).disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).count < 8) }
            }
        }
    }
}
