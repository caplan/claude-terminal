import Foundation

/// Locked read-modify-write helper for `~/.claude/settings.json`.
///
/// Claude Code itself doesn't coordinate writes to this file, so our flock
/// only protects against concurrent `claude-terminal` instances (two menu-bar
/// launches racing on install, or install racing with in-app Uninstall). The
/// lock file lives next to settings.json and is specific to us — we never
/// block Claude Code.
enum ClaudeSettings {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")

    private static let lockPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/.claude-terminal-settings.lock")

    /// Acquire an exclusive flock, read settings.json, let `body` mutate
    /// it, and write back atomically — but only if the serialized bytes
    /// actually differ from what's on disk. Returns true when a write
    /// occurred, false on no-op or error.
    ///
    /// `body` receives an empty dict if the file is missing or unparseable.
    /// Callers that need to preserve malformed content should detect that
    /// case by checking `settings.isEmpty` at the start of `body` and
    /// mutate nothing.
    @discardableResult
    static func mutate(_ body: (inout [String: Any]) -> Void) -> Bool {
        let fm = FileManager.default
        let dir = path.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let lockFd = open(lockPath.path, O_CREAT | O_WRONLY, 0o644)
        guard lockFd >= 0 else { return false }
        defer {
            flock(lockFd, LOCK_UN)
            close(lockFd)
        }
        flock(lockFd, LOCK_EX)

        let originalData = fm.contents(atPath: path.path)
        var settings: [String: Any] = [:]
        if let data = originalData,
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = parsed
        }

        body(&settings)

        guard let out = try? JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return false }

        if originalData == out { return false }

        do {
            try out.write(to: path, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
