import SwiftUI

struct WorkflowStatusView: View {
    @ObservedObject var workflow: AIWorkflowController

    var body: some View {
        switch workflow.state {
        case .idle:
            EmptyView()
        case .running(let label):
            HStack(spacing: 10) {
                ProgressView()
                Text(label).font(.subheadline).lineLimit(2)
                Spacer(minLength: 4)
                Button("停止") { workflow.cancel() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(12)
            .background(Color(uiColor: .secondarySystemBackground))
        case .completed(let message):
            StatusBanner(icon: "checkmark.circle.fill", color: .green, text: message)
        case .failed(let message):
            StatusBanner(icon: "exclamationmark.triangle.fill", color: .red, text: message)
        case .cancelled:
            StatusBanner(icon: "stop.circle", color: .secondary, text: "任务已停止；已接收的部分内容会作为候选保留。")
        }
    }
}

private struct StatusBanner: View {
    let icon: String
    let color: Color
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground))
    }
}
