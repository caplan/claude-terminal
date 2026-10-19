import SwiftUI

/// The /context breakdown under the sidebar's Context card: a stacked bar, one
/// row per category, the MCP tools and memory files behind two of them, and
/// Refresh and Compact buttons that ask the session's mod to act.
struct SidebarContextBreakdown: View {
    let breakdown: ContextBreakdown
    let isCompacting: Bool
    let sessionId: UUID

    @State private var showsMcpTools = false
    @State private var showsMemoryFiles = false
    /// Set by Refresh until a breakdown with a newer `measuredAt` arrives.
    @State private var refreshRequestedAt: Double?

    private var isRefreshing: Bool {
        guard let at = refreshRequestedAt else { return false }
        return breakdown.measuredAt < at
    }

    /// The rows the bar draws, in /context's order, with tokens to show.
    private var barRows: [ContextBreakdown.Row] {
        breakdown.rows.filter { $0.kind != "free" && $0.tokens > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(percent(breakdown.usedTokens))% used")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(sidebarFormatTokens(breakdown.usedTokens)) / \(sidebarFormatTokens(breakdown.windowTokens))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
            }
            bar
            VStack(alignment: .leading, spacing: 3) {
                ForEach(breakdown.rows, id: \.self) { row in
                    rowView(row)
                }
            }
            if !breakdown.mcpTools.isEmpty {
                disclosure("MCP tools", count: breakdown.mcpTools.count, isOpen: $showsMcpTools) {
                    ForEach(breakdown.mcpTools, id: \.self) { tool in
                        detailRow(tool.name, note: tool.server, tokens: tool.tokens)
                    }
                }
            }
            if !breakdown.memoryFiles.isEmpty {
                disclosure("Memory files", count: breakdown.memoryFiles.count, isOpen: $showsMemoryFiles) {
                    ForEach(breakdown.memoryFiles, id: \.self) { file in
                        detailRow((file.path as NSString).lastPathComponent, note: file.path, tokens: file.tokens)
                    }
                }
            }
            buttons
        }
    }

    private var bar: some View {
        GeometryReader { geo in
            let total = max(1, breakdown.windowTokens)
            HStack(spacing: 1) {
                ForEach(barRows, id: \.self) { row in
                    Rectangle()
                        .fill(color(for: row))
                        .frame(width: max(1, geo.size.width * CGFloat(row.tokens) / CGFloat(total)))
                }
                Spacer(minLength: 0)
            }
            .frame(height: 6)
            .background(Color(nsColor: .separatorColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .frame(height: 6)
    }

    private func rowView(_ row: ContextBreakdown.Row) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color(for: row))
                .frame(width: 8, height: 8)
            Text(row.name)
                .font(.system(size: 11))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(sidebarFormatTokens(row.tokens))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
            Text(String(format: "%.1f%%", share(row.tokens)))
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 42, alignment: .trailing)
        }
    }

    private func disclosure<Content: View>(
        _ title: String, count: Int, isOpen: Binding<Bool>, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                isOpen.wrappedValue.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isOpen.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 10)
                    Text(title).font(.system(size: 11))
                    Spacer()
                    Text("\(count)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen.wrappedValue {
                VStack(alignment: .leading, spacing: 2, content: content)
                    .padding(.leading, 14)
            }
        }
        .padding(.top, 2)
    }

    private func detailRow(_ name: String, note: String, tokens: Int) -> some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.system(size: 10.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(note)
            Spacer(minLength: 4)
            Text(sidebarFormatTokens(tokens))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Spacer()
            Button(isRefreshing ? "Refreshing…" : "Refresh") {
                refreshRequestedAt = Date().timeIntervalSince1970 * 1000
                ClaudeCodeIntegration.sendModRequest("refresh", sessionId: sessionId)
            }
            .disabled(isRefreshing || isCompacting)
            .help("Count every tool and memory file again. This sends about one API request per tool.")
            Button(isCompacting ? "Compacting…" : "Compact session") {
                ClaudeCodeIntegration.sendModRequest("compact", sessionId: sessionId)
            }
            .disabled(isCompacting)
            .help("Summarize the conversation to free context, as /compact does.")
        }
        .controlSize(.small)
        .padding(.top, 4)
    }

    private func percent(_ tokens: Int) -> Int {
        guard breakdown.windowTokens > 0 else { return 0 }
        return Int((Double(tokens) * 100 / Double(breakdown.windowTokens)).rounded())
    }

    private func share(_ tokens: Int) -> Double {
        guard breakdown.windowTokens > 0 else { return 0 }
        return Double(tokens) * 100 / Double(breakdown.windowTokens)
    }

    /// Colours by category, in the same spirit as /context: the large movable
    /// parts stand out, the fixed overhead is gray, free space is faint.
    private func color(for row: ContextBreakdown.Row) -> Color {
        switch row.kind {
        case "free": return Color(nsColor: .separatorColor).opacity(0.4)
        case "buffer": return Color(nsColor: .tertiaryLabelColor).opacity(0.5)
        default: break
        }
        switch row.name {
        case "MCP tools": return .blue
        case "Messages": return .orange
        case "System tools": return .green
        default: return Color(nsColor: .secondaryLabelColor).opacity(0.7)
        }
    }
}
