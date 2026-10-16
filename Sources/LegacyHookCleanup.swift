import Foundation

/// Removes what older claude-terminal versions installed for Claude Code: the
/// hook and statusLine entries in `~/.claude/settings.json`, and the scripts in
/// `~/.claude-terminal/hooks/`. The sidebar-bridge mod replaces all of them.
///
/// Runs on every launch, so a person who reinstalls an old version and then
/// this one is cleaned again. It writes settings.json only when an entry was
/// found (ClaudeSettings.mutate skips unchanged bytes).
enum LegacyHookCleanup {
    static func run() {
        removeLegacyScripts()
        removeSettingsEntries()
    }

    /// True for a hook entry, or a statusLine, whose command runs our helper.
    static func referencesClaudeTerminal(_ entry: [String: Any]) -> Bool {
        if let hookList = entry["hooks"] as? [[String: Any]] {
            return hookList.contains { ($0["command"] as? String)?.contains("claude-terminal") == true }
        }
        return (entry["command"] as? String)?.contains("claude-terminal") == true
    }

    /// Takes our entries out of a decoded settings.json. Shared with the
    /// in-app Uninstall.
    static func scrub(_ settings: inout [String: Any]) {
        if var hooks = settings["hooks"] as? [String: Any] {
            for (event, value) in hooks {
                guard var entries = value as? [[String: Any]] else { continue }
                entries.removeAll { referencesClaudeTerminal($0) }
                hooks[event] = entries.isEmpty ? nil : entries
            }
            settings["hooks"] = hooks.isEmpty ? nil : hooks
        }
        if let statusLine = settings["statusLine"] as? [String: Any],
           referencesClaudeTerminal(statusLine) {
            settings.removeValue(forKey: "statusLine")
        }
    }

    /// Rewrites settings.json only when it holds one of our entries, so a
    /// clean file keeps the person's own formatting and key order. A file that
    /// does not parse is left alone: mutate would write `{}` over it.
    private static func removeSettingsEntries() {
        guard let data = FileManager.default.contents(atPath: ClaudeSettings.path.path),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              containsOurHook(settings) else { return }
        ClaudeSettings.mutate { scrub(&$0) }
    }

    private static func containsOurHook(_ settings: [String: Any]) -> Bool {
        if let sl = settings["statusLine"] as? [String: Any], referencesClaudeTerminal(sl) { return true }
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { ($0 as? [[String: Any]])?.contains(where: referencesClaudeTerminal) == true }
    }

    /// Versions before the compiled helper ran shell scripts from here.
    private static func removeLegacyScripts() {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude-terminal/hooks")
        for name in ["update-status.sh", "statusline.sh"] {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
        try? fm.removeItem(atPath: fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-terminal/uninstall.sh").path)
        if (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
            try? fm.removeItem(at: dir)
        }
    }
}
