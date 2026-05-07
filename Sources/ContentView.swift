import SwiftUI

struct ContentView: View {
    @StateObject private var terminalSurface: TerminalSurface
    @ObservedObject var monitor: SessionMonitor
    @ObservedObject var sidebarState: SidebarState
    @ObservedObject var tabState: DocumentTabState

    let sessionId: UUID

    init(tabId: UUID, sessionId: UUID, sidebarState: SidebarState, monitor: SessionMonitor, tabState: DocumentTabState, workingDirectory: String? = nil, claudeOptions: String? = nil) {
        self.sessionId = sessionId
        self.sidebarState = sidebarState
        self.monitor = monitor
        self.tabState = tabState

        var config = CtSurfaceConfigTemplate()
        let claudeBin = AppDelegate.shared?.claudePath ?? "claude"
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        config.command = "\(shell) -l"
        var claudeCmd = claudeBin
        if let claudeOptions, !claudeOptions.isEmpty {
            claudeCmd += " \(claudeOptions)"
        }
        if let workingDirectory, !workingDirectory.isEmpty {
            config.workingDirectory = workingDirectory
        }
        config.environmentVariables["CLAUDE_TERMINAL_SESSION_ID"] = sessionId.uuidString
        // CLAUDE_CODE_EAGER_FLUSH triggers a flush call after every assistant
        // turn step inside the CLI (`await sR()`), which makes the transcript
        // JSONL hit disk sooner so our TranscriptTailer's DispatchSource fires
        // earlier. Doesn't add partial-message chunks (only --include-partial-
        // messages does, and it requires --print/--output-format=stream-json),
        // but it does shave latency between Claude finishing a step and us
        // seeing the bytes.
        config.environmentVariables["CLAUDE_CODE_EAGER_FLUSH"] = "1"
        if let userEnv = AppDelegate.shared?.userShellEnvironment {
            for (key, value) in userEnv {
                if config.environmentVariables[key] == nil {
                    config.environmentVariables[key] = value
                }
            }
        }
        if let claudeOptions, claudeOptions.contains("--continue") {
            let fallbackCmd = claudeCmd.replacingOccurrences(of: "--continue", with: "").replacingOccurrences(of: "  ", with: " ")
            config.initialInput = claudeCmd + " || " + fallbackCmd + "; exit\n"
        } else {
            config.initialInput = claudeCmd + "; exit\n"
        }

        let surface = TerminalSurface(
            tabId: tabId,
            context: GHOSTTY_SURFACE_CONTEXT_WINDOW,
            configTemplate: config
        )
        _terminalSurface = StateObject(wrappedValue: surface)
    }

    private var activeDocTab: DocumentTab? {
        guard let id = tabState.active else { return nil }
        return tabState.tabs.first(where: { $0.id == id })
    }

    var body: some View {
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
                        isActive: activeDocTab == nil,
                        isVisibleInUI: activeDocTab == nil,
                        searchState: terminalSurface.searchState
                    )
                    .opacity(activeDocTab == nil ? 1 : 0)
                    .allowsHitTesting(activeDocTab == nil)

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
            if let name = monitor.state.sessionName, !name.isEmpty {
                findWindow(for: sessionId)?.title = name
            }
        }
        .onDisappear { monitor.stopMonitoring() }
        .onChange(of: monitor.state.sessionName) { name in
            guard let name, !name.isEmpty else { return }
            findWindow(for: sessionId)?.title = name
        }
    }

    private func findWindow(for sessionId: UUID) -> NSWindow? {
        AppDelegate.shared?.windowForSession(sessionId)
    }
}
