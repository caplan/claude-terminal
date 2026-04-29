import Foundation

enum HookInstaller {
    private static let hookDirLegacy = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude-terminal/hooks")
    private static let claudeSettingsPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")

    /// Absolute path to the claude-terminal-hook executable inside the app bundle.
    /// Claude Code hooks invoke this via the command field in ~/.claude/settings.json.
    private static var helperBinaryPath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/claude-terminal-hook")
            .path
    }

    static func installIfNeeded() {
        removeLegacyPythonScripts()
        configureClaudeSettings()
    }

    /// Older versions of claude-terminal shelled out to Python scripts at
    /// ~/.claude-terminal/hooks/{update-status,statusline}.sh. Now replaced
    /// by the embedded claude-terminal-hook binary, so clean the old scripts
    /// up so stale copies can't run.
    private static func removeLegacyPythonScripts() {
        let fm = FileManager.default
        for name in ["update-status.sh", "statusline.sh"] {
            let path = hookDirLegacy.appendingPathComponent(name).path
            if fm.fileExists(atPath: path) {
                try? fm.removeItem(atPath: path)
            }
        }
    }

    private static func configureClaudeSettings() {
        let fm = FileManager.default
        let settingsPath = claudeSettingsPath.path
        let helper = helperBinaryPath

        var settings: [String: Any] = [:]
        if fm.fileExists(atPath: settingsPath),
           let data = fm.contents(atPath: settingsPath),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = parsed
        }

        let hookCommand = "\"\(helper)\" hook"
        let statusLineCommand = "\"\(helper)\" statusline"
        let desiredHooks = buildDesiredHooks(command: hookCommand)

        var existingHooks = settings["hooks"] as? [String: Any] ?? [:]
        var changed = false

        for (eventName, hookConfigs) in desiredHooks {
            // Replace any prior claude-terminal entries (old Python script or older binary path).
            let existingEntries = existingHooks[eventName] as? [[String: Any]] ?? []
            let filtered = existingEntries.filter { entry in
                if let hooks = entry["hooks"] as? [[String: Any]] {
                    return !hooks.contains { ($0["command"] as? String)?.contains("claude-terminal") == true }
                }
                if let cmd = entry["command"] as? String {
                    return !cmd.contains("claude-terminal")
                }
                return true
            }
            var updated = filtered
            updated.append(contentsOf: hookConfigs)
            if (updated as NSArray) != (existingEntries as NSArray) {
                existingHooks[eventName] = updated
                changed = true
            }
        }

        let existingStatusLine = settings["statusLine"] as? [String: Any]
        let currentStatusLineCmd = (existingStatusLine?["command"] as? String) ?? ""
        if currentStatusLineCmd != statusLineCommand {
            settings["statusLine"] = [
                "type": "command",
                "command": statusLineCommand,
                "refreshInterval": 3,
            ] as [String: Any]
            changed = true
        }

        if changed {
            settings["hooks"] = existingHooks
            if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
                let dir = (settingsPath as NSString).deletingLastPathComponent
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try? data.write(to: claudeSettingsPath, options: .atomic)
                print("[claude-terminal] Configured Claude Code hooks → \(helper)")
            }
        }
    }

    private static func buildDesiredHooks(command: String) -> [String: [[String: Any]]] {
        let entry: [String: Any] = [
            "matcher": "",
            "hooks": [
                ["type": "command", "command": command, "timeout": 5] as [String: Any]
            ],
        ]
        return [
            "SessionStart": [entry],
            "UserPromptSubmit": [entry],
            "PreToolUse": [entry],
            "PostToolUse": [entry],
            "Stop": [entry],
            "SubagentStart": [entry],
            "SubagentStop": [entry],
            "TaskCreated": [entry],
            "TaskCompleted": [entry],
            "Notification": [entry],
        ]
    }
}
