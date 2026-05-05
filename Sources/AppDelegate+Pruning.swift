import Foundation

extension AppDelegate {
    /// Called once at launch. No windows exist yet, so every session dir is
    /// orphaned from a previous run (normal quit leaves them behind). Also
    /// drops docs-by-dir / cost-by-session entries that refer to things no
    /// longer on disk.
    static func pruneStaleFiles() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default

        let sessionsDir = "\(home)/.claude-terminal/sessions"
        if let entries = try? fm.contentsOfDirectory(atPath: sessionsDir) {
            for name in entries {
                try? fm.removeItem(atPath: "\(sessionsDir)/\(name)")
            }
        }

        let docsPath = "\(home)/.claude-terminal/docs-by-dir.json"
        if let data = fm.contents(atPath: docsPath),
           let map = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] {
            let cleaned = map.filter { dir, _ in fm.fileExists(atPath: dir) }
                             .mapValues { paths in paths.filter { fm.fileExists(atPath: $0) } }
                             .filter { !$0.value.isEmpty }
            if cleaned.count != map.count {
                if let out = try? JSONSerialization.data(withJSONObject: cleaned, options: [.sortedKeys]) {
                    try? out.write(to: URL(fileURLWithPath: docsPath), options: .atomic)
                }
            }
        }

        let costPath = "\(home)/.claude-terminal/cost-by-session.json"
        if let data = fm.contents(atPath: costPath),
           let map = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let valid = knownClaudeCodeSessionIds(home: home)
            // If Claude Code's project dir doesn't exist at all, skip pruning —
            // Claude isn't installed or hasn't run here yet; don't wipe history.
            guard !valid.isEmpty else { return }
            let cleaned = map.filter { id, _ in valid.contains(id) }
            if cleaned.count != map.count {
                if let out = try? JSONSerialization.data(withJSONObject: cleaned, options: [.sortedKeys]) {
                    try? out.write(to: URL(fileURLWithPath: costPath), options: .atomic)
                }
            }
        }
    }

    /// Returns every Claude Code session id whose transcript file still
    /// exists on disk under ~/.claude/projects/<proj>/<id>.jsonl.
    private static func knownClaudeCodeSessionIds(home: String) -> Set<String> {
        let projectsDir = "\(home)/.claude/projects"
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(atPath: projectsDir) else {
            return []
        }
        var ids: Set<String> = []
        let suffix = ".jsonl"
        for proj in projects {
            let dir = "\(projectsDir)/\(proj)"
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for file in files where file.hasSuffix(suffix) {
                ids.insert(String(file.dropLast(suffix.count)))
            }
        }
        return ids
    }
}
