import SwiftUI

/// The window's session tabs: one chip per session, above the terminal and
/// the sidebar. It copies the look of the doc tab bar (TerminalTabBar) but is
/// its own type, because the two chips will drift apart.
struct SessionTabBar: View {
    static let height: CGFloat = 32
    /// The named coordinate space chip frames are measured in. It is the
    /// bar's own top-left origin, which is the hosting view's origin too.
    static let space = "sessionTabBar"

    @ObservedObject var sessions: WindowSessions

    /// True for the rail down the left side, false for the bar on top.
    private var vertical: Bool { sessions.barIsVertical }

    var body: some View {
        Group {
            if vertical {
                rail
            } else {
                bar
            }
        }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(ChipFramesKey.self) { sessions.chipFrames = $0 }
        .overlay(alignment: .topLeading) { insertionMarker }
    }

    private var bar: some View {
        HStack(spacing: 4) {
            chips
            newTabButton
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(VisualEffectBackground(material: .titlebar))
        .overlay(
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private var rail: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 2) {
                chips
                newTabButton
                    .padding(.leading, 4)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VisualEffectBackground(material: .sidebar))
        .overlay(
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1),
            alignment: .trailing
        )
    }

    private var chips: some View {
        ForEach(sessions.sessionIds, id: \.self) { sessionId in
            if let record = AppDelegate.shared?.sessions[sessionId] {
                SessionTabChip(
                    monitor: record.monitor,
                    isActive: sessionId == sessions.activeSessionId,
                    hasSiblings: sessions.sessionIds.count > 1,
                    vertical: vertical,
                    onSelect: { AppDelegate.shared?.activateSession(sessionId) },
                    onClose: { AppDelegate.shared?.closeSession(sessionId) },
                    onCloseOthers: { AppDelegate.shared?.closeOtherSessions(in: sessions.windowId, keeping: sessionId) },
                    onRename: { AppDelegate.shared?.promptRename(sessionId: sessionId) },
                    onMoveToNewWindow: { AppDelegate.shared?.moveSessionToNewWindow(sessionId) }
                )
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ChipFramesKey.self,
                            value: [sessionId: proxy.frame(in: .named(Self.space))]
                        )
                    }
                )
                // A drag that leaves the bar keeps its updates: AppKit sends
                // every mouse-dragged event to the window the press began in.
                .gesture(
                    DragGesture(minimumDistance: 5)
                        .onChanged { _ in TabDragController.shared.update(sessionId: sessionId) }
                        .onEnded { _ in TabDragController.shared.end() }
                )
            }
        }
    }

    private var newTabButton: some View {
        Button {
            AppDelegate.shared?.createNewTab()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22)
                if vertical {
                    Text("New Tab")
                        .font(.system(size: 11))
                }
            }
            .foregroundColor(Color(nsColor: .secondaryLabelColor))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("New Tab (⌘T)")
    }

    /// A short accent line between chips, where a dragged tab would land.
    @ViewBuilder
    private var insertionMarker: some View {
        if let index = sessions.dropIndex, let rect = markerRect(at: index) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.accentColor)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }

    private func markerRect(at index: Int) -> CGRect? {
        let frames = sessions.sessionIds.compactMap { sessions.chipFrames[$0] }
        guard !frames.isEmpty else { return nil }
        if vertical {
            let y = index < frames.count ? frames[index].minY - 1 : frames[frames.count - 1].maxY + 1
            let x = frames[0].minX
            return CGRect(x: x, y: y - 1, width: frames[0].width, height: 2)
        }
        let x = index < frames.count ? frames[index].minX - 2 : frames[frames.count - 1].maxX + 2
        let y = frames[0].minY
        return CGRect(x: x - 1, y: y, width: 2, height: frames[0].height)
    }
}

/// Each chip's frame in the bar's named coordinate space, keyed by session.
private struct ChipFramesKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct SessionTabChip: View {
    @ObservedObject var monitor: SessionMonitor
    let isActive: Bool
    let hasSiblings: Bool
    let vertical: Bool
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
            if vertical { Spacer(minLength: 0) }
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
        .padding(.vertical, vertical ? 6 : 4)
        .frame(maxWidth: vertical ? .infinity : 220, alignment: .leading)
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
