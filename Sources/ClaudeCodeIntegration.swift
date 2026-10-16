import AppKit

/// How claude-terminal receives session events from Claude Code: the bundled
/// `sidebar-bridge` mod, loaded into each session we launch through
/// `CLAUDE_CODE_PLUGIN_DIRS`. Nothing is written to `~/.claude/settings.json`.
struct ClaudeCodeVersion: Comparable, CustomStringConvertible {
    let parts: [Int]

    /// The first build whose events carry everything the mod reads: `agentId`
    /// on `turn.start` and `turn.complete`, `agent.spawn`'s agent id,
    /// `session.measure` and `tool.check`. Checked with `claude plugin validate`
    /// and `tsc` against that build's plugin-authoring types.
    static let minimum = ClaudeCodeVersion(parts: [2, 1, 301])

    /// Parses `claude --version` output, e.g. `2.1.301 (Claude Code)`.
    init?(versionOutput: String) {
        guard let token = versionOutput
            .split(whereSeparator: { $0.isWhitespace })
            .first else { return nil }
        let nums = token.split(separator: ".").map { Int($0) }
        guard nums.count >= 2, !nums.contains(where: { $0 == nil }) else { return nil }
        parts = nums.compactMap { $0 }
    }

    init(parts: [Int]) { self.parts = parts }

    static func < (lhs: ClaudeCodeVersion, rhs: ClaudeCodeVersion) -> Bool {
        for i in 0..<max(lhs.parts.count, rhs.parts.count) {
            let l = i < lhs.parts.count ? lhs.parts[i] : 0
            let r = i < rhs.parts.count ? rhs.parts[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    var description: String { parts.map(String.init).joined(separator: ".") }
}

enum ClaudeCodeIntegration {
    /// Runs `claude --version` with a timeout. nil when it fails, hangs or
    /// prints something we can't parse.
    static func probeVersion(claudePath: String, environment: [String: String]?) -> ClaudeCodeVersion? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: claudePath)
        proc.arguments = ["--version"]
        if let environment { proc.environment = environment }
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in exited.signal() }
        do { try proc.run() } catch { return nil }
        if exited.wait(timeout: .now() + 5) == .timedOut {
            proc.terminate()
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard proc.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else { return nil }
        return ClaudeCodeVersion(versionOutput: output)
    }

    /// Blocks launch until the CLI at `claudePath` is new enough. Below the
    /// minimum the sidebar would get no events, so the person updates Claude
    /// Code, picks another binary, or quits.
    static func requireSupportedVersion(claudePath: inout String, environment: [String: String]?) {
        while true {
            let version = probeVersion(claudePath: claudePath, environment: environment)
            if let version, version >= .minimum { return }

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Claude Code \(ClaudeCodeVersion.minimum) or newer is required"
            let found = version.map { "Claude Code \($0)" } ?? "a Claude Code version claude-terminal could not read"
            alert.informativeText = """
                \(claudePath) is \(found).

                claude-terminal gets its sidebar data from a Claude Code mod, which needs \(ClaudeCodeVersion.minimum) or newer.

                Update with: claude update
                """
            alert.addButton(withTitle: "Try Again")
            alert.addButton(withTitle: "Choose claude…")
            alert.addButton(withTitle: "Quit")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                continue
            case .alertSecondButtonReturn:
                if let path = AppDelegate.shared?.askUserForClaudePath() { claudePath = path }
            default:
                NSApp.terminate(nil)
                return
            }
        }
    }

    /// The `sidebar-bridge` plugin folder inside the app bundle.
    static var modDirectoryPath: String {
        AppBundlePaths.resources.appendingPathComponent("sidebar-bridge-mod").path
    }

    /// The claude-terminal-hook executable inside the app bundle, which the mod
    /// runs (as `CLAUDE_TERMINAL_HOOK`) to write status.json.
    static var helperBinaryPath: String {
        AppBundlePaths.resources.appendingPathComponent("claude-terminal-hook").path
    }

    /// Environment for each Claude Code session the app launches.
    static func sessionEnvironment(existingPluginDirs: String?) -> [String: String] {
        var dirs = [modDirectoryPath]
        if let existingPluginDirs, !existingPluginDirs.isEmpty {
            dirs.append(existingPluginDirs)
        }
        return [
            "CLAUDE_CODE_PLUGIN_DIRS": dirs.joined(separator: ":"),
            "CLAUDE_CODE_ENABLE_FUNCTION_HOOKS": "1",
            "CLAUDE_TERMINAL_HOOK": helperBinaryPath,
        ]
    }
}

enum AppBundlePaths {
    /// `Contents/Resources` of the running app.
    ///
    /// Resolved via executableURL, not bundleURL: when launched through the
    /// /usr/local/bin/claude-terminal symlink, Bundle.main.bundleURL falls back
    /// to /usr/local/bin (Foundation can't find Contents/Info.plist relative to
    /// the symlink).
    static var resources: URL {
        let exe = (Bundle.main.executableURL ?? Bundle.main.bundleURL).resolvingSymlinksInPath()
        let bundle = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return bundle.appendingPathComponent("Contents/Resources")
    }
}
