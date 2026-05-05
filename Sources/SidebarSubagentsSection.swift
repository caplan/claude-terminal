import AppKit
import SwiftUI

/// Section card content — list of in-flight subagents spawned by the host
/// session, with a colored status dot, the agent's name, an optional
/// running-tool chip, and the human-readable tool detail. Right-click on
/// any row exposes a Force Quit affordance routed back to the monitor.
struct SubagentsSection: View {
    @ObservedObject var monitor: SessionMonitor

    private var state: SessionState { monitor.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Subagents")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(nsColor: .secondaryLabelColor))
                .textCase(.uppercase)
                .tracking(0.5)
            ForEach(state.subagents) { agent in
                HStack(spacing: 8) {
                    Circle()
                        .fill(sidebarStatusColor(agent.status))
                        .frame(width: 6, height: 6)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(agent.name)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.primary)
                            if let tool = agent.currentTool {
                                Text(tool)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(sidebarToolColor(tool))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(sidebarToolColor(tool).opacity(0.12))
                                    .cornerRadius(3)
                            }
                        }
                        if let desc = agent.description {
                            Text(desc)
                                .font(.system(size: 12))
                                .foregroundColor(Color(nsColor: .secondaryLabelColor))
                                .lineLimit(1)
                        }
                        if let tool = agent.currentTool, let detail = agent.toolDetail, !detail.isEmpty {
                            Text(sidebarToolDetailLabel(tool, detail: detail))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }
                }
                .contextMenu {
                    Button("Force Quit") {
                        monitor.removeSubagent(agent.id)
                    }
                }
            }
        }
    }
}
