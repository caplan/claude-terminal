import Foundation

enum HookInstaller {
    private static let hookDirLegacy = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude-terminal/hooks")

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
        writeStandaloneUninstaller()
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
        let helper = helperBinaryPath
        let hookCommand = "\"\(helper)\" hook"
        let statusLineCommand = "\"\(helper)\" statusline"
        let desiredHooks = buildDesiredHooks(command: hookCommand)

        ClaudeSettings.mutate { settings in
            var existingHooks = settings["hooks"] as? [String: Any] ?? [:]

            // Strip stale claude-terminal entries from EVERY event, not just
            // the ones we still install into. This cleans up orphans left
            // behind when the set of desired events changes between versions
            // (e.g. a future release removes Notification).
            for (eventName, value) in existingHooks {
                guard var entries = value as? [[String: Any]] else { continue }
                entries.removeAll { entryReferencesClaudeTerminal($0) }
                existingHooks[eventName] = entries.isEmpty ? nil : entries
            }

            // Install the current helper into desired events.
            for (eventName, hookConfigs) in desiredHooks {
                var entries = existingHooks[eventName] as? [[String: Any]] ?? []
                entries.append(contentsOf: hookConfigs)
                existingHooks[eventName] = entries
            }

            settings["hooks"] = existingHooks.isEmpty ? nil : existingHooks
            settings["statusLine"] = [
                "type": "command",
                "command": statusLineCommand,
                "refreshInterval": 3,
            ] as [String: Any]
        }
    }

    private static func entryReferencesClaudeTerminal(_ entry: [String: Any]) -> Bool {
        if let hookList = entry["hooks"] as? [[String: Any]] {
            return hookList.contains { ($0["command"] as? String)?.contains("claude-terminal") == true }
        }
        return (entry["command"] as? String)?.contains("claude-terminal") == true
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

    /// Copy a standalone uninstall script to ~/.claude-terminal/uninstall.sh
    /// on every launch. This survives drag-to-Trash (the app bundle goes but
    /// ~/.claude-terminal stays), giving users a recovery path for cleaning
    /// Claude Code hooks + preferences without the app binary. Written
    /// idempotently — same content each time, no thrash.
    private static func writeStandaloneUninstaller() {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude-terminal").path
        let scriptPath = "\(dir)/uninstall.sh"
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let content = StandaloneUninstallScript.content
        if let existing = try? String(contentsOfFile: scriptPath, encoding: .utf8),
           existing == content {
            return
        }
        do {
            try content.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            // chmod +x — FileManager.setAttributes with posixPermissions.
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        } catch {
            print("[claude-terminal] Failed to write standalone uninstaller: \(error)")
        }
    }
}

