import AppKit
import SwiftUI

/// One session's saved form: what Save & Quit needs to reopen it as a tab.
struct SessionConfig: Codable {
    var workingDirectory: String
    var claudeOptions: String?
    var sessionName: String?
    var openDocs: [OpenDocState]?
    var activeDocPath: String?
    var customBackgroundHex: String?
}

/// One window's saved form (format version 2): its tabs in order, which one
/// is in front, and the window-level sidebar and tab-rail settings. Version 1
/// (`WindowConfig`, one session per window) is still read and converted.
struct WindowSnapshot: Codable {
    var version: Int = 2
    var sessions: [SessionConfig]
    var activeIndex: Int
    var sidebarVisible: Bool
    var sidebarWidth: Double?
    var railWidth: Double?

    init(sessions: [SessionConfig], activeIndex: Int, sidebarVisible: Bool, sidebarWidth: Double?, railWidth: Double?) {
        self.sessions = sessions
        self.activeIndex = activeIndex
        self.sidebarVisible = sidebarVisible
        self.sidebarWidth = sidebarWidth
        self.railWidth = railWidth
    }

    init(legacy config: WindowConfig) {
        self.sessions = [SessionConfig(
            workingDirectory: config.workingDirectory,
            claudeOptions: config.claudeOptions,
            sessionName: config.sessionName,
            openDocs: config.openDocs,
            activeDocPath: config.activeDocPath,
            customBackgroundHex: config.customBackgroundHex
        )]
        self.activeIndex = 0
        self.sidebarVisible = config.sidebarVisible
        self.sidebarWidth = config.sidebarWidth
        self.railWidth = nil
    }
}

/// Everything the app keeps for one Claude session. AppDelegate creates one
/// per session and SwiftUI never rebuilds it, so the TerminalSurface (and the
/// Ghostty surface behind it) is made exactly once.
final class SessionRecord {
    let sessionId: UUID
    let tabId: UUID
    let monitor: SessionMonitor
    let tabState: DocumentTabState
    let surface: TerminalSurface
    var config: SessionConfig

    init(sessionId: UUID, tabId: UUID, monitor: SessionMonitor, tabState: DocumentTabState, surface: TerminalSurface, config: SessionConfig) {
        self.sessionId = sessionId
        self.tabId = tabId
        self.monitor = monitor
        self.tabState = tabState
        self.surface = surface
        self.config = config
    }

    /// Builds the surface that runs `claude` in `workingDirectory`. Moved out
    /// of `ContentView.init` so a SwiftUI re-render can never create a second
    /// surface for the same session.
    static func makeSurface(tabId: UUID, sessionId: UUID, workingDirectory: String?, claudeOptions: String?) -> TerminalSurface {
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
        let userPluginDirs = AppDelegate.shared?.userShellEnvironment?["CLAUDE_CODE_PLUGIN_DIRS"]
        for (key, value) in ClaudeCodeIntegration.sessionEnvironment(existingPluginDirs: userPluginDirs, sessionId: sessionId) {
            config.environmentVariables[key] = value
        }
        if let userEnv = AppDelegate.shared?.userShellEnvironment {
            for (key, value) in userEnv {
                if config.environmentVariables[key] == nil {
                    config.environmentVariables[key] = value
                }
            }
        }
        // Auto-close the window only on a clean (exit 0) claude exit. On an
        // abnormal exit (crash, signal, error), keep the login shell open so
        // the error output stays on screen — otherwise the window vanishes
        // silently and looks like an app crash — and append a one-line record
        // to a log so past exits are diagnosable even if unattended.
        let closeTail =
            "; __ct_ec=$?; if [ \"$__ct_ec\" -eq 0 ]; then exit; else "
            + "printf '\\n[claude exited with status %s - shell kept open; type exit to close]\\n' \"$__ct_ec\"; "
            + "echo \"$(date '+%FT%T%z') status=$__ct_ec dir=$PWD\" >>\"$HOME/Library/Logs/claude-terminal-exits.log\" 2>/dev/null; "
            + "fi\n"
        if let claudeOptions, claudeOptions.contains("--continue") {
            let fallbackCmd = claudeCmd.replacingOccurrences(of: "--continue", with: "").replacingOccurrences(of: "  ", with: " ")
            config.initialInput = "( " + claudeCmd + " || " + fallbackCmd + " )" + closeTail
        } else {
            config.initialInput = claudeCmd + closeTail
        }

        return TerminalSurface(
            tabId: tabId,
            context: GHOSTTY_SURFACE_CONTEXT_WINDOW,
            configTemplate: config
        )
    }
}

/// The ordered sessions of one window and which one is in front. Window-level
/// tab state lives here; the sidebar's visibility and width stay in
/// `SidebarState`, also per window.
final class WindowSessions: ObservableObject {
    let windowId: UUID
    @Published var sessionIds: [UUID] = []
    @Published var activeSessionId: UUID?
    /// Width of the vertical tab rail, when the tab bar is on the left.
    @Published var railWidth: CGFloat

    init(windowId: UUID, railWidth: CGFloat? = nil) {
        self.windowId = windowId
        self.railWidth = railWidth ?? 220
    }
}
