import SwiftUI

/// One session's view: its terminal, its doc tabs and its sidebar. The
/// TerminalSurface comes in through the SessionRecord, which AppDelegate owns,
/// so this view can be rebuilt by SwiftUI without spawning a new terminal.
struct ContentView: View {
    @ObservedObject var terminalSurface: TerminalSurface
    @ObservedObject var monitor: SessionMonitor
    @ObservedObject var sidebarState: SidebarState
    @ObservedObject var tabState: DocumentTabState

    let sessionId: UUID
    /// False when another tab of the same window is in front. The terminal
    /// then stays mounted but hidden, so the portal binding survives.
    var isActiveSession: Bool

    init(record: SessionRecord, sidebarState: SidebarState, isActiveSession: Bool = true) {
        self.sessionId = record.sessionId
        self.terminalSurface = record.surface
        self.monitor = record.monitor
        self.tabState = record.tabState
        self.sidebarState = sidebarState
        self.isActiveSession = isActiveSession
    }

    private var activeDocTab: DocumentTab? {
        guard let id = tabState.active else { return nil }
        return tabState.tabs.first(where: { $0.id == id })
    }

    var body: some View {
        // The terminal is in front only when this session is the window's
        // active one and no doc tab covers it.
        let terminalInFront = isActiveSession && activeDocTab == nil
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if !tabState.tabs.isEmpty {
                    TerminalTabBar(state: tabState)
                }
                ZStack(alignment: .topTrailing) {
                    Color(nsColor: .textBackgroundColor)

                    GhosttyTerminalView(
                        terminalSurface: terminalSurface,
                        paneId: UUID(),
                        isActive: terminalInFront,
                        isVisibleInUI: terminalInFront,
                        searchState: terminalSurface.searchState
                    )
                    .opacity(terminalInFront ? 1 : 0)
                    .allowsHitTesting(terminalInFront)

                    // Keep every open doc's viewer mounted so scroll position
                    // (and image zoom) survives switching tabs. Dispatch by
                    // extension: markdown → WKWebView with our renderer,
                    // images → NSImageView.
                    ForEach(tabState.tabs) { tab in
                        Group {
                            if ViewableDocument.isImage(tab.path) {
                                ImageViewerView(tabId: tab.id, path: tab.path)
                            } else {
                                MarkdownViewerView(tabId: tab.id, path: tab.path, tabState: tabState)
                            }
                        }
                        .opacity(tabState.active == tab.id ? 1 : 0)
                        .allowsHitTesting(tabState.active == tab.id)
                    }

                    if tabState.findActive, activeDocTab != nil {
                        DocFindBar(tabState: tabState)
                            .padding(.top, 8)
                            .padding(.trailing, 12)
                            .transition(.opacity)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if sidebarState.isVisible {
                SidebarDragHandle(sidebarState: sidebarState)
                SidebarHostView(monitor: monitor, tabState: tabState, width: sidebarState.width)
            }
        }
        .onAppear {
            monitor.startMonitoring()
            if isActiveSession, let name = monitor.state.sessionName, !name.isEmpty {
                findWindow(for: sessionId)?.title = name
            }
        }
        .onDisappear { monitor.stopMonitoring() }
        .onChange(of: monitor.state.sessionName) { name in
            guard isActiveSession, let name, !name.isEmpty else { return }
            findWindow(for: sessionId)?.title = name
        }
    }

    private func findWindow(for sessionId: UUID) -> NSWindow? {
        AppDelegate.shared?.window(forSession: sessionId)
    }
}
