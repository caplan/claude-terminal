import Foundation

/// Rolling-window context-usefulness tracker.
///
/// For each tool the assistant runs, record an `Artifact` with a set of
/// anchors — short strings that, if they appear in a later turn's text
/// or tool input, suggest the loaded chunk is being used. Anchors come
/// from two places:
///   1. The tool's input (file basename, command name, URL host, first
///      ≥3-char word of a pattern/query/subject).
///   2. Distinctive symbols extracted from the tool's *result* — class /
///      struct / func / type / interface declarations, etc. — so a Read
///      of `AuthMiddleware.kt` lights up later when the assistant
///      mentions `AuthMiddleware.refreshToken`, even if the basename
///      never reappears.
///
/// Three-layer reference signal, from strongest to weakest:
///   - **Tool-call reuse:** if a later tool's input contains any anchor
///     of an earlier artifact, that artifact is definitively used. This
///     is the only signal that bypasses the noise filter.
///   - **Haystack substring match:** the anchor appears in a later
///     window turn's outbound text/JSON.
///   - **Noise filter:** anchors that show up in >50% of the rolling
///     window are treated as un-distinctive (e.g., `main.swift`,
///     `Bash`-command names that run constantly). They don't earn an
///     artifact "referenced" credit on their own.
///
/// Token estimate = chars/4 of the artifact's tool_result.
/// Mirrors `scripts/analyze-snapshot.py` semantics.
final class ContextWasteTracker {
    private struct Artifact {
        let toolUseId: String
        /// All anchors for this artifact: primary anchor from tool
        /// input + symbols extracted from tool_result.
        var anchors: Set<String>
        /// What we show in "Top dead artifacts" — the primary anchor.
        let displayKey: String
        let tool: String
        let turnIdx: Int
        var estTokens: Int = 0
        /// Set when a *later* tool_use's input contains any of this
        /// artifact's anchors. Stronger than substring-in-prose: if a
        /// downstream Edit/Bash/Grep is targeting this file or symbol,
        /// the load was actually used. Bypasses the noise filter.
        var reusedByLaterTool: Bool = false
        /// Whether to symbol-mine this artifact's tool_result for
        /// additional anchors. True for Read/Edit/Write/NotebookEdit/Grep,
        /// and for Bash when the command is a file previewer (cat/head/…).
        let extractSymbolsOnResult: Bool
    }

    struct DeadArtifact {
        let key: String
        let tool: String
        let estTokens: Int
        let turnIdx: Int
    }

    private struct WindowedTurn {
        let turnIdx: Int
        let haystack: String
    }

    private var artifacts: [Artifact] = []
    private var indexByToolUseId: [String: Int] = [:]
    private var window: [WindowedTurn] = []

    static let defaultWindowTurns = 10
    private var windowTurns: Int {
        let raw = UserDefaults.standard.integer(forKey: "contextWasteWindowTurns")
        return raw > 0 ? raw : Self.defaultWindowTurns
    }

    func recordToolUse(turnIdx: Int, toolUseId: String, name: String, input: [String: Any]) {
        guard !toolUseId.isEmpty,
              let extracted = Self.extractAnchor(name: name, input: input),
              !extracted.anchor.isEmpty else { return }

        // Strong-signal-first: scan this tool's input for any earlier
        // artifact's anchors. If the new tool is targeting an earlier
        // chunk's basename / extracted symbol, the chunk was used.
        let inputJSON = Self.encodeJSON(input)
        if !inputJSON.isEmpty {
            for i in artifacts.indices where !artifacts[i].reusedByLaterTool
                                          && artifacts[i].toolUseId != toolUseId {
                for anchor in artifacts[i].anchors where anchor.count >= 4 {
                    if inputJSON.contains(anchor) {
                        artifacts[i].reusedByLaterTool = true
                        break
                    }
                }
            }
        }

        let a = Artifact(toolUseId: toolUseId,
                         anchors: [extracted.anchor],
                         displayKey: extracted.anchor,
                         tool: name,
                         turnIdx: turnIdx,
                         extractSymbolsOnResult: extracted.extractSymbols)
        indexByToolUseId[toolUseId] = artifacts.count
        artifacts.append(a)
    }

    /// Records the tool_result content. The content is used to
    /// estimate tokens (chars/4) and, for code-emitting tools, to
    /// extract distinctive symbols that get added to the artifact's
    /// anchor set.
    func recordToolResult(toolUseId: String, content: String) {
        guard let i = indexByToolUseId[toolUseId] else { return }
        artifacts[i].estTokens = max(1, content.count / 4)
        if artifacts[i].extractSymbolsOnResult {
            let symbols = Self.extractSymbols(from: content)
            if !symbols.isEmpty {
                artifacts[i].anchors.formUnion(symbols)
            }
        }
    }

    /// Append the new turn's haystack to the rolling window. Call once
    /// per unique assistant turn. The `haystack` should be assistant
    /// text + tool_use input JSON. Artifacts are NOT evicted by age —
    /// an artifact loaded 100 turns ago still occupies cache tokens
    /// and the right question is whether its anchors show up in the
    /// recent window.
    func scanReferences(turnIdx: Int, haystack: String) {
        window.append(WindowedTurn(turnIdx: turnIdx, haystack: haystack))
        let n = windowTurns
        if window.count > n {
            window.removeFirst(window.count - n)
        }
    }

    /// `(percent unused, total tokens, unused tokens)` over every
    /// artifact loaded in the session. An artifact counts as referenced
    /// if (a) `reusedByLaterTool` was set by a downstream tool, or (b)
    /// any of its non-noisy anchors appears in a window turn strictly
    /// after its loading turn. Artifacts loaded in the current turn are
    /// excluded — they haven't had a chance to be referenced yet, so
    /// counting them would bias every freshly-loaded file as wasted.
    /// Returns nil if the sample is too small or no turns have been
    /// scanned.
    func summary(currentTurnIdx: Int) -> (unusedPct: Int, totalTokens: Int, unusedTokens: Int)? {
        guard !window.isEmpty else { return nil }
        let noisy = computeNoisyAnchors()
        var total = 0
        var unused = 0
        for a in artifacts where a.estTokens > 0 && a.turnIdx < currentTurnIdx {
            total += a.estTokens
            if !isReferenced(a, noisy: noisy) { unused += a.estTokens }
        }
        guard total >= 500 else { return nil }
        return (Int(Double(unused) / Double(total) * 100), total, unused)
    }

    /// Top dead artifacts by estimated tokens, for the
    /// "what's wasting your context" disclosure.
    func topDeadArtifacts(currentTurnIdx: Int, limit: Int = 5) -> [DeadArtifact] {
        guard !window.isEmpty else { return [] }
        let noisy = computeNoisyAnchors()
        var dead: [DeadArtifact] = []
        for a in artifacts where a.estTokens > 0 && a.turnIdx < currentTurnIdx {
            if isReferenced(a, noisy: noisy) { continue }
            dead.append(DeadArtifact(key: a.displayKey, tool: a.tool,
                                      estTokens: a.estTokens, turnIdx: a.turnIdx))
        }
        dead.sort { $0.estTokens > $1.estTokens }
        if dead.count > limit { dead = Array(dead.prefix(limit)) }
        return dead
    }

    private func isReferenced(_ a: Artifact, noisy: Set<String>) -> Bool {
        if a.reusedByLaterTool { return true }
        for wt in window where wt.turnIdx > a.turnIdx {
            for anchor in a.anchors where !noisy.contains(anchor) {
                if wt.haystack.contains(anchor) { return true }
            }
        }
        return false
    }

    /// An anchor is "noisy" if it shows up in more than half of the
    /// rolling window's haystacks — at that frequency it can't
    /// distinguish a referenced chunk from background noise. Falls
    /// back to empty (no filtering) when the window is too small to
    /// estimate frequency.
    private func computeNoisyAnchors() -> Set<String> {
        guard window.count >= 4 else { return [] }
        var allAnchors = Set<String>()
        for a in artifacts {
            allAnchors.formUnion(a.anchors)
        }
        let threshold = window.count / 2
        var noisy = Set<String>()
        for anchor in allAnchors {
            var hits = 0
            for wt in window {
                if wt.haystack.contains(anchor) {
                    hits += 1
                    if hits > threshold { break }
                }
            }
            if hits > threshold { noisy.insert(anchor) }
        }
        return noisy
    }

    func reset() {
        artifacts.removeAll(keepingCapacity: false)
        indexByToolUseId.removeAll(keepingCapacity: false)
        window.removeAll(keepingCapacity: false)
    }

    // MARK: - Anchor extraction (from tool input)

    private static func extractAnchor(
        name: String, input: [String: Any]
    ) -> (anchor: String, extractSymbols: Bool)? {
        switch name {
        case "Read", "Edit", "Write":
            if let p = input["file_path"] as? String {
                let base = (p as NSString).lastPathComponent
                return base.isEmpty ? nil : (base, true)
            }
        case "NotebookEdit":
            if let p = input["notebook_path"] as? String {
                let base = (p as NSString).lastPathComponent
                return base.isEmpty ? nil : (base, true)
            }
        case "Bash":
            if let cmd = input["command"] as? String { return bashAnchor(cmd) }
        case "Glob":
            if let p = input["pattern"] as? String,
               let t = firstWordToken(p) { return (t, false) }
        case "Grep":
            if let p = input["pattern"] as? String,
               let t = firstWordToken(p) { return (t, true) }
        case "WebFetch":
            if let url = input["url"] as? String,
               let host = URL(string: url)?.host { return (host, false) }
        case "WebSearch":
            if let q = input["query"] as? String,
               let t = firstWordToken(q) { return (t, false) }
        case "Task", "TaskCreate", "TaskUpdate":
            for key in ["subject", "description", "prompt"] {
                if let s = input[key] as? String,
                   let t = firstWordToken(s) { return (t, false) }
            }
        default:
            if name.hasPrefix("mcp__") {
                for key in ["query", "url", "path", "name", "id"] {
                    if let s = input[key] as? String,
                       let t = firstWordToken(s) { return (t, false) }
                }
            }
            return nil
        }
        return nil
    }

    private static func firstWordToken(_ s: String) -> String? {
        var word = String.UnicodeScalarView()
        for sc in s.unicodeScalars {
            if CharacterSet.alphanumerics.contains(sc) || sc == "_" {
                word.append(sc)
            } else if !word.isEmpty {
                break
            }
        }
        let str = String(word)
        return str.count >= 3 ? str : nil
    }

    /// Commands whose first non-flag argument is the thing actually being
    /// loaded into context (usually a file). We skip the command itself so
    /// the anchor locks onto the file, and flip the symbol-mining flag on
    /// so the tool_result gets symbol-extracted like a Read would.
    private static let previewerCommands: Set<String> = [
        "cat", "head", "tail", "less", "more", "nl", "bat"
    ]

    private static func bashAnchor(_ command: String) -> (anchor: String, extractSymbols: Bool)? {
        let separators = CharacterSet(charactersIn: " \t\n|;&")
        var previewerSeen = false
        var previewerName: String?
        for raw in command.components(separatedBy: separators) {
            let tok = raw.trimmingCharacters(in: .whitespaces)
            guard !tok.isEmpty else { continue }
            if tok.hasPrefix("-") { continue }
            if let eq = tok.firstIndex(of: "="),
               tok[..<eq].allSatisfy({ $0.isUppercase || $0 == "_" }) {
                continue
            }
            let basename = (tok as NSString).lastPathComponent
            if !previewerSeen && Self.previewerCommands.contains(basename) {
                previewerSeen = true
                previewerName = basename
                continue
            }
            return (basename, previewerSeen)
        }
        // Previewer with no subsequent argument (e.g. piped from stdin) —
        // fall back to the previewer name; no file content to mine.
        if let p = previewerName { return (p, false) }
        return nil
    }

    // MARK: - Symbol extraction (from tool result)

    /// Captures top-level declarations across common languages: Swift,
    /// Kotlin, Java, JS/TS, Python, Go, Rust, Ruby, C++. Cap the
    /// scanned content at 64 KB so a giant Read doesn't make the regex
    /// the bottleneck.
    private static let symbolRegex: NSRegularExpression? = {
        let pattern = #"\b(?:class|struct|enum|protocol|interface|trait|impl|type|func|fn|function|def|sub|object|record|module|package)\s+([A-Za-z_][A-Za-z0-9_]{3,})"#
        return try? NSRegularExpression(pattern: pattern)
    }()

    private static let exportRegex: NSRegularExpression? = {
        let pattern = #"\bexport\s+(?:default\s+)?(?:async\s+)?(?:class|function|const|let|var)\s+([A-Za-z_][A-Za-z0-9_]{3,})"#
        return try? NSRegularExpression(pattern: pattern)
    }()

    private static func extractSymbols(from content: String) -> Set<String> {
        guard !content.isEmpty else { return [] }
        let snippet: String
        if content.count > 65_536 {
            snippet = String(content.prefix(65_536))
        } else {
            snippet = content
        }
        var out = Set<String>()
        let nsRange = NSRange(snippet.startIndex..., in: snippet)
        let collect: (NSTextCheckingResult?) -> Void = { match in
            guard let m = match, m.numberOfRanges > 1,
                  let r = Range(m.range(at: 1), in: snippet) else { return }
            let name = String(snippet[r])
            if isDistinctiveSymbol(name) { out.insert(name) }
        }
        symbolRegex?.enumerateMatches(in: snippet, range: nsRange) { m, _, _ in collect(m) }
        exportRegex?.enumerateMatches(in: snippet, range: nsRange) { m, _, _ in collect(m) }
        return out
    }

    /// Drop names that are too short or too common to distinguish a
    /// referenced chunk from coincidence. Keep this list tight — the
    /// noise filter (>50% window-presence) catches symbol noise too,
    /// so this is just a fast-path reject for the worst offenders.
    private static let symbolStopwords: Set<String> = [
        "init", "main", "self", "this", "true", "false", "null", "None",
        "make", "Make", "type", "Type", "Item", "Data", "Info", "Util",
        "Value", "Object", "String", "Number", "Array", "List", "Dict",
        "Map", "Set", "Bool", "char", "Char", "Test", "test", "Mock",
        "mock", "Stub", "stub", "Fake", "fake", "Base", "base", "Util",
        "util", "Util", "Helper", "helper", "Default", "default"
    ]

    private static func isDistinctiveSymbol(_ s: String) -> Bool {
        if s.count < 4 { return false }
        if symbolStopwords.contains(s) { return false }
        return true
    }

    private static func encodeJSON(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }
}
