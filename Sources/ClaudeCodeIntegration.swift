import Foundation

/// How claude-terminal receives session events from Claude Code.
///
/// Chosen once at launch from `claude --version`. Builds that load function-hook
/// mods get the bundled `sidebar-bridge` mod through `CLAUDE_CODE_PLUGIN_DIRS`
/// on each session we launch. The mod sends tool start, tool end and turn end;
/// `~/.claude/settings.json` keeps the statusLine and the low-frequency hooks
/// whose classic input carries fields no native event has. Older builds keep
/// every settings.json hook entry.
enum ClaudeIntegrationMode: String {
    case classicHooks = "classic"
    case mods = "mods"
}

struct ClaudeCodeVersion: Comparable, CustomStringConvertible {
    let parts: [Int]

    /// The first build the bundled mod was checked against
    /// (`claude plugin validate`, plugin-authoring types 2.1.286).
    static let minimumForMods = ClaudeCodeVersion(parts: [2, 1, 286])

    /// Parses `claude --version` output, e.g. `2.1.287 (Claude Code)`.
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
    /// `defaults write org.claire.claude-terminal claudeIntegrationMode classic`
    /// (or `mods`) pins the mode; anything else, or unset, means detect.
    private static let overrideKey = "claudeIntegrationMode"

    static func detectMode(claudePath: String, environment: [String: String]?) -> (ClaudeIntegrationMode, ClaudeCodeVersion?) {
        let version = probeVersion(claudePath: claudePath, environment: environment)
        if let raw = UserDefaults.standard.string(forKey: overrideKey),
           let pinned = ClaudeIntegrationMode(rawValue: raw) {
            return (pinned, version)
        }
        guard let version, version >= .minimumForMods, modDirectoryPath != nil else {
            return (.classicHooks, version)
        }
        return (.mods, version)
    }

    /// Runs `claude --version` with a timeout. nil when it fails, hangs or
    /// prints something we can't parse; the caller then stays on classic hooks.
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

    /// The `sidebar-bridge` plugin folder inside the app bundle.
    static var modDirectoryPath: String? {
        let path = AppBundlePaths.resources.appendingPathComponent("sidebar-bridge-mod").path
        return FileManager.default.fileExists(atPath: "\(path)/.claude-plugin/plugin.json") ? path : nil
    }

    /// Environment for a Claude Code session in `.mods` mode.
    static func sessionEnvironment(existingPluginDirs: String?) -> [String: String] {
        guard let modDir = modDirectoryPath else { return [:] }
        var dirs = [modDir]
        if let existingPluginDirs, !existingPluginDirs.isEmpty {
            dirs.append(existingPluginDirs)
        }
        return [
            "CLAUDE_CODE_PLUGIN_DIRS": dirs.joined(separator: ":"),
            "CLAUDE_CODE_ENABLE_FUNCTION_HOOKS": "1",
            "CLAUDE_TERMINAL_HOOK": HookInstaller.helperBinaryPath,
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
