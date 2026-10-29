import SwiftUI

/// The window's session tabs: one chip per session, above the terminal and
/// the sidebar. It copies the look of the doc tab bar (TerminalTabBar) but is
/// its own type, because the two chips will drift apart.
struct SessionTabBar: View {
    static let height: CGFloat = 32

    @ObservedObject var sessions: WindowSessions

    var body: some View {
        HStack(spacing: 4) {
            ForEach(sessions.sessionIds, id: \.self) { sessionId in
                if let record = AppDelegate.shared?.sessions[sessionId] {
                    SessionTabChip(
                        monitor: record.monitor,
                        isActive: sessionId == sessions.activeSessionId,
                        hasSiblings: sessions.sessionIds.count > 1,
                        onSelect: { AppDelegate.shared?.activateSession(sessionId) },
                        onClose: { AppDelegate.shared?.closeSession(sessionId) },
                        onCloseOthers: { AppDelegate.shared?.closeOtherSessions(in: sessions.windowId, keeping: sessionId) },
                        onRename: { AppDelegate.shared?.promptRename(sessionId: sessionId) },
                        onMoveToNewWindow: { AppDelegate.shared?.moveSessionToNewWindow(sessionId) }
                    )
                }
            }
            Button {
                AppDelegate.shared?.createNewTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(nsColor: .secondaryLabelColor))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Tab (⌘T)")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .background(VisualEffectBackground(material: .titlebar))
        .overlay(
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1),
            alignment: .bottom
        )
    }
}

private struct SessionTabChip: View {
    @ObservedObject var monitor: SessionMonitor
    let isActive: Bool
    let hasSiblings: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void
    let onRename: () -> Void
    let onMoveToNewWindow: () -> Void

    @State private var hovering = false

    private var name: String {
        monitor.state.sessionName
            ?? (monitor.state.workingDirectory as NSString?)?.lastPathComponent
            ?? "Session"
    }

    /// A background tab that waits for the user gets a ring around its dot.
    /// The active tab shows that state in the terminal itself.
    private var needsAttention: Bool {
        !isActive && (monitor.state.needsInput ?? false)
    }

    var body: some View {
        HStack(spacing: 6) {
            icon
            Text(name)
                .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                .foregroundColor(isActive ? .primary : Color(nsColor: .secondaryLabelColor))
                .lineLimit(1)
                .truncationMode(.middle)
            statusDot
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    .padding(2)
                    .background(
                        Circle()
                            .fill(hovering ? Color(nsColor: .quaternaryLabelColor) : .clear)
                    )
            }
            .buttonStyle(.plain)
            // Always on the active tab, on hover for the others. The space is
            // kept either way so the chip does not change width on hover.
            .opacity(hovering || isActive ? 1 : 0)
            .help("Close Tab (⌘W)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: 220)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color(nsColor: .controlBackgroundColor) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isActive ? Color(nsColor: .separatorColor) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onSelect() }
        .contextMenu {
            Button("Rename…", action: onRename)
            Button("Move Tab to New Window", action: onMoveToNewWindow)
                .disabled(!hasSiblings)
            Divider()
            Button("Close Tab", action: onClose)
            Button("Close Other Tabs", action: onCloseOthers)
                .disabled(!hasSiblings)
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let favicon = FaviconLoader.favicon(for: monitor.state.workingDirectory, size: 14) {
            Image(nsImage: favicon)
                .resizable()
                .frame(width: 14, height: 14)
        } else {
            Image(systemName: "terminal")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(isActive ? .primary : Color(nsColor: .secondaryLabelColor))
        }
    }

    private var statusDot: some View {
        ZStack {
            if needsAttention {
                Circle()
                    .stroke(Color.accentColor, lineWidth: 1.5)
                    .frame(width: 11, height: 11)
            }
            Circle()
                .fill(SessionStatusStyle.color(monitor.state.status))
                .frame(width: 6, height: 6)
        }
        .frame(width: 11, height: 11)
        .help(SessionStatusStyle.label(monitor.state.status))
    }
}
