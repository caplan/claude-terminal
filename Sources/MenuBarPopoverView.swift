import SwiftUI

struct MenuBarPopoverView: View {
    @ObservedObject var viewModel: SessionListViewModel
    var dismiss: () -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sessions")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button(action: {
                    dismiss()
                    AppDelegate.shared?.createNewWindow()
                }) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(Color(nsColor: .secondaryLabelColor))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if viewModel.sessions.isEmpty {
                Text("No sessions")
                    .font(.system(size: 14))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    ForEach(viewModel.sessions) { session in
                        SessionCard(session: session)
                            .onTapGesture { handleTap(session) }
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 660)
        .background(VisualEffectBackground(material: .popover))
    }

    private func handleTap(_ session: SessionEntry) {
        dismiss()
        if session.isActive {
            AppDelegate.shared?.focusWindow(windowId: session.id)
        } else {
            AppDelegate.shared?.openPastSession(directory: session.workingDirectory, sessionName: session.sessionName)
        }
    }
}

private struct CardBoundsReader: NSViewRepresentable {
    let isHovered: Bool
    let session: SessionEntry

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        if isHovered {
            DispatchQueue.main.async {
                guard let window = nsView.window else { return }
                let rectInWindow = nsView.convert(nsView.bounds, to: nil)
                let rectOnScreen = window.convertToScreen(rectInWindow)
                let anchor = NSPoint(x: rectOnScreen.midX, y: rectOnScreen.maxY)
                TooltipWindow.shared.show(
                    name: session.sessionName,
                    directory: session.workingDirectory,
                    anchor: anchor
                )
            }
        }
    }
}

private struct SessionCard: View {
    let session: SessionEntry
    @State private var isHovered = false
    private static let cardHeight: CGFloat = 110

    private var cardBackground: Color {
        if let custom = session.customBackground {
            return Color(nsColor: custom.withAlphaComponent(session.isActive ? 0.85 : 0.55))
        }
        if let dominant = FaviconLoader.dominantColor(for: session.workingDirectory) {
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            dominant.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let bgColor: NSColor
            if isDark {
                bgColor = NSColor(hue: h, saturation: s * 0.35, brightness: 0.25, alpha: session.isActive ? 0.8 : 0.5)
            } else {
                bgColor = NSColor(hue: h, saturation: s * 0.25, brightness: 0.95, alpha: session.isActive ? 0.8 : 0.5)
            }
            return Color(nsColor: bgColor)
        }
        return session.isActive
            ? Color(nsColor: .controlBackgroundColor).opacity(0.4)
            : Color(nsColor: .controlBackgroundColor).opacity(0.2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                if let favicon = FaviconLoader.favicon(for: session.workingDirectory, size: 20) {
                    Image(nsImage: favicon)
                        .resizable()
                        .frame(width: 20, height: 20)
                        .padding(.top, 1)
                }
                Text(session.sessionName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(session.isActive ? .primary : Color(nsColor: .secondaryLabelColor))
                    .lineLimit(2)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Circle()
                    .fill(session.isActive ? statusColor(session.status) : Color(nsColor: .separatorColor))
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)
            }

            Spacer(minLength: 0)

            Text(compactDir(session.workingDirectory))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 8) {
                Text(statusLabel(session.status))
                    .font(.system(size: 12))
                    .foregroundColor(session.isActive ? statusColor(session.status) : Color(nsColor: .tertiaryLabelColor))
                if let cost = session.costUsd, cost > 0 {
                    Text(formatCost(cost))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                }
                if session.isActive, let turns = session.conversationTurns, turns > 0 {
                    Text("\(turns) turns")
                        .font(.system(size: 12))
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: Self.cardHeight)
        .background(cardBackground.opacity(isHovered ? 1.0 : 0.85))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isHovered
                    ? Color(nsColor: .selectedControlColor).opacity(0.7)
                    : Color(nsColor: .separatorColor).opacity(session.isActive ? 0.5 : 0.3),
                        lineWidth: isHovered ? 1.5 : 0.5)
        )
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .shadow(color: .black.opacity(isHovered ? 0.15 : 0), radius: 4, y: 2)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .background(CardBoundsReader(isHovered: isHovered, session: session))
        .onHover { hovering in
            isHovered = hovering
            if !hovering { TooltipWindow.shared.hide() }
        }
        .contentShape(Rectangle())
        .contextMenu {
            if !session.isActive {
                Button("Delete…") {
                    TooltipWindow.shared.hide()
                    AppDelegate.shared?.promptDeletePastSession(
                        directory: session.workingDirectory,
                        sessionName: session.sessionName
                    )
                }
            }
        }
    }

    private func statusColor(_ status: SessionStatus) -> Color {
        switch status {
        case .idle: return .gray
        case .thinking: return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 0.95, green: 0.65, blue: 0.15, alpha: 1)
                : NSColor(red: 0.75, green: 0.45, blue: 0.05, alpha: 1)
        })
        case .toolUse: return .blue
        case .streaming: return .green
        case .disconnected: return Color(nsColor: .separatorColor)
        }
    }

    private func statusLabel(_ status: SessionStatus) -> String {
        switch status {
        case .idle: return "Idle"
        case .thinking: return "Thinking..."
        case .toolUse: return "Using tool"
        case .streaming: return "Streaming"
        case .disconnected: return "Disconnected"
        }
    }

    private func compactDir(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var display = path
        if display.hasPrefix(home) {
            display = "~" + display.dropFirst(home.count)
        }
        let parts = display.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.count <= 3 { return display }
        let first = parts[0]
        let last = parts[parts.count - 1]
        return first + "/\u{2026}/" + last
    }

    private func formatCost(_ usd: Double) -> String {
        if usd < 0.01 { return String(format: "$%.4f", usd) }
        return String(format: "$%.2f", usd)
    }
}
