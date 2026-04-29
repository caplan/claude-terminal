import Foundation

/// Caches "filename + short excerpt" metadata for markdown documents shown
/// in the sidebar. The sidebar re-renders on every session-state change,
/// and reading these files on each render would be wasteful; cache by path
/// and invalidate on mtime change.
enum DocumentExcerptCache {
    struct Excerpt {
        let title: String
        let excerpt: String
    }

    private static var cache: [String: (mtime: Date, value: Excerpt)] = [:]
    private static let lock = NSLock()

    static func excerpt(for path: String) -> Excerpt {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date.distantPast

        lock.lock()
        if let cached = cache[path], cached.mtime == mtime {
            lock.unlock()
            return cached.value
        }
        lock.unlock()

        let content = readPrefix(path: path, bytes: 4096)
        let parsed = parse(content: content)

        lock.lock()
        cache[path] = (mtime, parsed)
        lock.unlock()
        return parsed
    }

    private static func readPrefix(path: String, bytes: Int) -> String {
        guard let fh = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? fh.close() }
        let data = (try? fh.read(upToCount: bytes)) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func parse(content: String) -> Excerpt {
        var title = ""
        var body = ""
        var inFence = false

        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inFence.toggle(); continue }
            if inFence || line.isEmpty { continue }
            if title.isEmpty, line.hasPrefix("#") {
                title = String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
                continue
            }
            if body.isEmpty, !line.hasPrefix("#") {
                body = stripLightMarkdown(line)
            }
            if !title.isEmpty && !body.isEmpty { break }
        }
        return Excerpt(title: title, excerpt: body)
    }

    private static func stripLightMarkdown(_ line: String) -> String {
        var s = line
        for ch: Character in ["*", "_", "`", ">"] {
            s = String(s.filter { $0 != ch })
        }
        if s.hasPrefix("- ") || s.hasPrefix("* ") { s.removeFirst(2) }
        return s.trimmingCharacters(in: .whitespaces)
    }
}
