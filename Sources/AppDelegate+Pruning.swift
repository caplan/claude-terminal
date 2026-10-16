import Foundation

extension AppDelegate {
    /// Called once at launch. Session dirs persist across runs so the menubar
    /// popover can list past sessions; we cap retention so they don't grow
    /// without bound. Also drops docs-by-dir / cost-by-session entries that
    /// refer to things no longer on disk, and bounds the files that otherwise
    /// only grow: MetricKit reports, the debug log, interrupted-write temp files
    /// and the exit log.
    static func pruneStaleFiles() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default

        pruneSessionDirs(home: home, fm: fm)
        pruneDiagnostics(fm: fm)
        removeStaleDebugLog(home: home, fm: fm)
        removeInterruptedWrites(home: home, fm: fm)
        truncateExitLog(home: home, fm: fm)
        pruneMaps(home: home, fm: fm)
    }

    private static func pruneMaps(home: String, fm: FileManager) {
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
            let path = "\(sessionsDir)/\(entry.name)"
            let tooOld = entry.mtime < cutoff
            let overCap = idx >= sessionRetentionMaxCount
            if tooOld || overCap {
                try? fm.removeItem(atPath: path)
                continue
            }
            // Drop entries whose recorded cwd has been deleted on disk —
            // they'd just be filtered out of the popover at read time anyway.
            if let data = fm.contents(atPath: "\(path)/status.json"),
               let state = try? JSONDecoder().decode(SessionState.self, from: data),
               let dir = state.workingDirectory, !dir.isEmpty {
                var isDir: ObjCBool = false
                if !fm.fileExists(atPath: dir, isDirectory: &isDir) || !isDir.boolValue {
                    try? fm.removeItem(atPath: path)
                }
            }
        }
    }

    /// MetricKit writes a `<stamp>-diagnostic.json` or `<stamp>-metric.json`
    /// per payload and nothing removes them. Keep the newest few; crash.log
    /// bounds itself (CrashCapture).
    private static let diagnosticsKeepCount = 10

    private static func pruneDiagnostics(fm: FileManager) {
        let dir = diagnosticsDirectory
        guard let files = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let reports = files
            .filter { $0.pathExtension == "json" }
            .map { url in
                (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }
            .sorted { $0.1 > $1.1 }
        for (url, _) in reports.dropFirst(diagnosticsKeepCount) {
            try? fm.removeItem(at: url)
        }
    }

    /// ActivityChartView writes ~/.claude-terminal/debug.log only in a Debug
    /// build or with CT_DEBUG_LOG set. Outside those, a debug.log is left over
    /// from an earlier session that had it on.
    private static func removeStaleDebugLog(home: String, fm: FileManager) {
        #if !DEBUG
        guard ProcessInfo.processInfo.environment["CT_DEBUG_LOG"] == nil else { return }
        try? fm.removeItem(atPath: "\(home)/.claude-terminal/debug.log")
        #endif
    }

    /// Foundation's atomic writes stage a `<name>.sb-<hash>-<random>` file
    /// beside the target and rename it into place. One that outlived its write
    /// is an interrupted save; an hour's age keeps a write in progress safe.
    private static func removeInterruptedWrites(home: String, fm: FileManager) {
        let dir = "\(home)/.claude-terminal"
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
        let cutoff = Date(timeIntervalSinceNow: -3600)
        for name in names where name.contains(".sb-") {
            let path = "\(dir)/\(name)"
            let mtime = (try? fm.attributesOfItem(atPath: path)[.modificationDate]) as? Date
            if (mtime ?? .distantPast) < cutoff {
                try? fm.removeItem(atPath: path)
            }
        }
    }

    /// The shell each window runs appends one line per abnormal claude exit
    /// (ContentView). Past the cap, keep the newest half of its lines.
    private static let exitLogMaxBytes = 256 * 1024

    private static func truncateExitLog(home: String, fm: FileManager) {
        let path = "\(home)/Library/Logs/claude-terminal-exits.log"
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int, size > exitLogMaxBytes,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let kept = lines.suffix(lines.count / 2).joined(separator: "\n") + "\n"
        try? kept.write(toFile: path, atomically: true, encoding: .utf8)
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
