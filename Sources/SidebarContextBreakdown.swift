import SwiftUI

/// The /context breakdown under the sidebar's Context card: the percent used, a
/// stacked bar, and Refresh and Compact buttons that ask the session's mod to
/// act. A Details disclosure, closed by default, holds one row per category and
/// the MCP tools and memory files behind two of them.
struct SidebarContextBreakdown: View {
    let breakdown: ContextBreakdown
    let isCompacting: Bool
    let sessionId: UUID

    /// One preference for every window, kept across relaunches, as the
    /// Documents section keeps its own.
    @AppStorage("contextDetailsExpanded") private var showsDetails = false
    @State private var showsMcpTools = false
    @State private var showsMemoryFiles = false
    /// Set by Refresh until a breakdown with a newer `measuredAt` arrives.
    @State private var refreshRequestedAt: Double?

    private var isRefreshing: Bool {
        guard let at = refreshRequestedAt else { return false }
        return breakdown.measuredAt < at
    }

    /// The rows by usage, largest first. The compact buffer and free space
    /// are no usage, so they come last, in that order, whatever their size.
    private var sortedRows: [ContextBreakdown.Row] {
        let used = breakdown.rows.filter { $0.kind != "free" && $0.kind != "buffer" }
            .sorted { $0.tokens > $1.tokens }
        let rest = breakdown.rows.filter { $0.kind == "buffer" } + breakdown.rows.filter { $0.kind == "free" }
        return used + rest
    }

    /// The rows the bar draws, in the same order as the list, with tokens to show.
    private var barRows: [ContextBreakdown.Row] {
        sortedRows.filter { $0.kind != "free" && $0.tokens > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(breakdown.percentUsed)% used")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(sidebarContextBarColor(breakdown.fractionUsed))
                Spacer()
                Text("\(sidebarFormatTokens(breakdown.usedTokens)) / \(sidebarFormatTokens(breakdown.windowTokens))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
            }
            bar
            disclosure("Details", count: nil, isOpen: $showsDetails) {
                details
            }
            buttons
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(sortedRows, id: \.self) { row in
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
        _ title: String, count: Int?, isOpen: Binding<Bool>, @ViewBuilder content: () -> Content
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
                    if let count {
                        Text("\(count)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    }
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

    /// Icon buttons; the name and what each does show on mouseover. While
    /// one runs, a spinner takes its icon's place.
    private var buttons: some View {
        HStack(spacing: 6) {
            Spacer()
            iconButton(
                isRefreshing ? "Refreshing…" : "Refresh",
                systemImage: "arrow.clockwise",
                isBusy: isRefreshing,
                help: "Refresh: count every tool and memory file again. This sends about one API request per tool."
            ) {
                refreshRequestedAt = Date().timeIntervalSince1970 * 1000
                ClaudeCodeIntegration.sendModRequest("refresh", sessionId: sessionId)
            }
            .disabled(isRefreshing || isCompacting)
            iconButton(
                isCompacting ? "Compacting…" : "Compact session",
                systemImage: "arrow.down.right.and.arrow.up.left",
                isBusy: isCompacting,
                help: isCompacting ? "Compacting…" : "Compact session: summarize the conversation to free context, as /compact does."
            ) {
                ClaudeCodeIntegration.sendModRequest("compact", sessionId: sessionId)
            }
            .disabled(isCompacting)
        }
        .controlSize(.small)
        .padding(.top, 4)
    }

    private func iconButton(
        _ title: String, systemImage: String, isBusy: Bool, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if isBusy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .frame(width: 18, height: 14)
        }
        .help(help)
        .accessibilityLabel(title)
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
