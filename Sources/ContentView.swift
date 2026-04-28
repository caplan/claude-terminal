import SwiftUI

struct ContentView: View {
    @StateObject private var terminalSurface: TerminalSurface
    @ObservedObject var monitor: SessionMonitor
    @ObservedObject var sidebarState: SidebarState

    let sessionId: UUID

    init(tabId: UUID, sessionId: UUID, sidebarState: SidebarState, monitor: SessionMonitor, workingDirectory: String? = nil, claudeOptions: String? = nil) {
        self.sessionId = sessionId
        self.sidebarState = sidebarState
        self.monitor = monitor

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

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Color(nsColor: .textBackgroundColor)

                GhosttyTerminalView(
                    terminalSurface: terminalSurface,
                    paneId: UUID(),
                    isActive: true,
                    isVisibleInUI: true
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if sidebarState.isVisible {
                SidebarDragHandle(sidebarState: sidebarState)
                SidebarHostView(monitor: monitor, width: sidebarState.width)
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
