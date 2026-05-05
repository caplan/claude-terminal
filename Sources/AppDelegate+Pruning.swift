import Foundation

extension AppDelegate {
    /// Called once at launch. Session dirs persist across runs so the menubar
    /// popover can list past sessions; we cap retention so they don't grow
    /// without bound. Also drops docs-by-dir / cost-by-session entries that
    /// refer to things no longer on disk.
    static func pruneStaleFiles() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default

        pruneSessionDirs(home: home, fm: fm)

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

    /// Retention policy for ~/.claude-terminal/sessions/<uuid>/. Keeps dirs
    /// modified within the cutoff, capped at a max count (newest-first). Older
    /// / excess dirs are removed. Both bounds apply — whichever fires first.
    private static let sessionRetentionDays: TimeInterval = 30
    private static let sessionRetentionMaxCount: Int = 100

    private static func pruneSessionDirs(home: String, fm: FileManager) {
        let sessionsDir = "\(home)/.claude-terminal/sessions"
        guard let entries = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return }

        let cutoff = Date(timeIntervalSinceNow: -sessionRetentionDays * 24 * 3600)
        // Sort by mtime descending: newest first. Anything past the max-count
        // or older than the cutoff gets dropped.
        let scored: [(name: String, mtime: Date)] = entries.compactMap { name in
            let path = "\(sessionsDir)/\(name)"
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date else {
                return (name, .distantPast)
            }
            return (name, mtime)
        }.sorted { $0.mtime > $1.mtime }

        for (idx, entry) in scored.enumerated() {
            let tooOld = entry.mtime < cutoff
            let overCap = idx >= sessionRetentionMaxCount
            if tooOld || overCap {
                try? fm.removeItem(atPath: "\(sessionsDir)/\(entry.name)")
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
