import Foundation

/// Snapshot of derived state from the Claude Code transcript JSONL. The tailer
/// rebuilds this on every meaningful line so SwiftUI can render the sidebar
/// without re-parsing the file itself.
struct TranscriptSnapshot: Equatable {
    /// Most recent assistant text (latched until the next user prompt).
    var latestText: String?
    /// Last few assistant text blocks within the current turn, oldest first.
    /// Cleared when the user submits a new prompt.
    var recentTexts: [String]
    /// Wall-clock duration of the most recently completed turn.
    var lastTurnDurationMs: Int?
    /// Tool-call count of the most recently completed turn.
    var lastTurnToolCount: Int?
    /// Tool errors of the most recently completed turn.
    var lastTurnErrorCount: Int?
    /// Tool errors observed so far in the still-running turn.
    var currentTurnErrorCount: Int
    /// When the current user prompt was submitted, for live elapsed display.
    var currentTurnStart: Date?
    /// Cost decomposition for the most recent assistant turn (deduped by
    /// `message.id`).
    var lastTurnCost: LLMTurnCost?
    /// Prompt tokens (input + cache_read + cache_creation) for that turn.
    var lastTurnPromptTokens: Int?
    /// Seconds between the prior assistant turn ending and the user prompt
    /// that triggered this one. >300s correlates with cache-TTL rebuilds.
    var lastTurnIdleSecsBefore: Int?
    /// Running session totals (deduped by `message.id`).
    var sessionTotalCost: Double
    /// Sum of `cacheCreate` across the session — the reclaimable bucket.
    var sessionReclaimableCost: Double
    var sessionUniqueRequests: Int
    /// Percentage of token-weighted Read/Edit/Write artifacts loaded this
    /// session that were never referenced by a later turn. nil while the
    /// sample is too small to be meaningful.
    var contextUnusedPct: Int?
    /// Token budget the percentage was computed against (denominator).
    var contextTrackedTokens: Int?
    /// Tokens summed directly from artifacts that aged past the lag window
    /// without being referenced — accurate, not derived from the rounded %.
    var contextUnusedTokens: Int?
    /// Top dead artifacts by est_tokens, for the "what's wasting your
    /// context" disclosure. Capped at 5 entries, sorted descending.
    var contextDeadArtifacts: [DeadArtifactEntry]

    struct DeadArtifactEntry: Equatable {
        let key: String
        let tool: String
        let estTokens: Int
    }

    static let empty = TranscriptSnapshot(
        latestText: nil,
        recentTexts: [],
        lastTurnDurationMs: nil,
        lastTurnToolCount: nil,
        lastTurnErrorCount: nil,
        currentTurnErrorCount: 0,
        currentTurnStart: nil,
        lastTurnCost: nil,
        lastTurnPromptTokens: nil,
        lastTurnIdleSecsBefore: nil,
        sessionTotalCost: 0,
        sessionReclaimableCost: 0,
        sessionUniqueRequests: 0,
        contextUnusedPct: nil,
        contextTrackedTokens: nil,
        contextUnusedTokens: nil,
        contextDeadArtifacts: []
    )
}

/// Watches a Claude Code transcript JSONL file and emits a `TranscriptSnapshot`
/// whenever a meaningful entry is appended. Uses DispatchSource to react to
/// file writes, seeking only the new bytes since the last read.
final class TranscriptTailer {
    private let queue = DispatchQueue(label: "org.claire.claude-terminal.transcript", qos: .utility)
    private var fd: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private var retryTimer: DispatchSourceTimer?
    private var offset: UInt64 = 0
    private var lineBuffer = Data()
    private var currentPath: String?
    private let onSnapshot: (TranscriptSnapshot) -> Void

    private var snapshot = TranscriptSnapshot.empty
    private var currentTurnTools = 0
    /// Claude Code splits one assistant response across multiple JSONL records
    /// that share the same `message.id` and `usage` field. Without this set
    /// every cost metric doubles.
    private var seenMessageIds = Set<String>()
    /// Timestamp of the most recent assistant record, used to compute the
    /// idle gap before the next user prompt.
    private var lastAssistantDate: Date?
    /// Set when a user-prompt line is seen; consumed by the next assistant
    /// turn to record `lastTurnIdleSecsBefore`.
    private var pendingIdleSecs: Int?
    private let waste = ContextWasteTracker()
    /// Monotonic counter of unique assistant LLM requests; provides a turn
    /// index to ContextWasteTracker so artifacts loaded "this turn" can't
    /// match themselves.
    private var assistantTurnCounter: Int = 0
    private static let recentTextLimit = 3
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(onSnapshot: @escaping (TranscriptSnapshot) -> Void) {
        self.onSnapshot = onSnapshot
    }

    deinit {
        source?.cancel()
        if fd >= 0 { close(fd) }
    }

    func watch(path: String) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.currentPath != path else { return }
            self.cleanup()
            self.currentPath = path
            self.snapshot = .empty
            self.currentTurnTools = 0
            self.seenMessageIds.removeAll(keepingCapacity: false)
            self.lastAssistantDate = nil
            self.pendingIdleSecs = nil
            self.waste.reset()
            self.assistantTurnCounter = 0
            // Publish the blank snapshot immediately — /clear swaps to a
            // new JSONL, but the file starts empty so no processLine call
            // will fire until the user types. Without this, SwiftUI keeps
            // rendering the pre-clear context bar.
            let snap = self.snapshot
            DispatchQueue.main.async { [onSnapshot = self.onSnapshot] in onSnapshot(snap) }
            self.open(path: path, seekToEnd: false)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.currentPath = nil
            self?.cleanup()
        }
    }

    // MARK: - Private

    private func cleanup() {
        source?.cancel()
        source = nil
        retryTimer?.cancel()
        retryTimer = nil
        if fd >= 0 { close(fd); fd = -1 }
        offset = 0
        lineBuffer.removeAll(keepingCapacity: false)
    }

    private func open(path: String, seekToEnd: Bool) {
        let newFd = Darwin.open(path, O_EVTONLY)
        if newFd < 0 {
            scheduleRetry(path: path)
            return
        }
        fd = newFd
        if seekToEnd {
            let end = lseek(newFd, 0, SEEK_END)
            offset = end < 0 ? 0 : UInt64(end)
        } else {
            offset = 0
            drain(path: path)
        }
        startDispatchSource(fd: newFd, path: path)
    }

    private func scheduleRetry(path: String) {
        retryTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.currentPath == path else { self.retryTimer?.cancel(); self.retryTimer = nil; return }
            let f = Darwin.open(path, O_EVTONLY)
            guard f >= 0 else { return }
            self.retryTimer?.cancel()
            self.retryTimer = nil
            self.fd = f
            self.offset = 0
            self.drain(path: path)
            self.startDispatchSource(fd: f, path: path)
        }
        timer.resume()
        retryTimer = timer
    }

    private func startDispatchSource(fd: Int32, path: String) {
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let event = src.data
            if event.contains(.rename) || event.contains(.delete) {
                self.cleanup()
                self.queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    guard let self, self.currentPath == path else { return }
                    self.open(path: path, seekToEnd: false)
                }
                return
            }
            self.drain(path: path)
        }
        src.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fd >= 0 { close(self.fd); self.fd = -1 }
        }
        src.resume()
        source = src
    }

    private func drain(path: String) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
        } catch {
            return
        }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
        offset += UInt64(data.count)
        lineBuffer.append(data)
        let newline: UInt8 = 0x0A
        var start = lineBuffer.startIndex
        var lastNewline: Int? = nil
        var idx = start
        var changed = false
        while idx < lineBuffer.endIndex {
            if lineBuffer[idx] == newline {
                if processLine(lineBuffer.subdata(in: start..<idx)) {
                    changed = true
                }
                lastNewline = idx
                start = lineBuffer.index(after: idx)
            }
            idx = lineBuffer.index(after: idx)
        }
        if let lastNewline {
            lineBuffer = lineBuffer.subdata(in: lineBuffer.index(after: lastNewline)..<lineBuffer.endIndex)
        }
        if changed {
            let snap = snapshot
            DispatchQueue.main.async { [onSnapshot] in onSnapshot(snap) }
        }
    }

    /// Returns true if the snapshot changed in any way and consumers should be
    /// re-notified.
    private func processLine(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let type = obj["type"] as? String

        if type == "user" {
            // /compact writes a synthetic user record with isCompactSummary=true.
            // From this point the model's next prompt drops the pre-compact
            // history, so every pre-existing artifact is no longer in the
            // prompt and shouldn't count toward "context waste". Reset the
            // tracker (but keep session cost — that's cumulative and still
            // accurate). Publish immediately so the context bar snaps back
            // to neutral without waiting for the next assistant turn.
            if (obj["isCompactSummary"] as? Bool) == true {
                waste.reset()
                seenMessageIds.removeAll(keepingCapacity: false)
                assistantTurnCounter = 0
                snapshot.contextUnusedPct = nil
                snapshot.contextTrackedTokens = nil
                snapshot.contextUnusedTokens = nil
                snapshot.contextDeadArtifacts = []
                snapshot.lastTurnPromptTokens = nil
                resetTurn()
                return true
            }
            // Background-task notifications are injected as user messages
            // with an XML payload (<task-notification>...<summary>...</summary>).
            // They aren't real user prompts — surface the summary so the
            // sidebar reflects "Background command X completed" the same way
            // the TUI does.
            if let summary = Self.extractTaskNotificationSummary(obj) {
                snapshot.latestText = summary
                appendRecentText(summary)
                return true
            }
            // Distinguish a real prompt (string content or content sans
            // tool_result blocks) from a tool_result entry. tool_results
            // happen mid-turn and shouldn't reset the assistant trace.
            if Self.isUserPrompt(obj) {
                if let last = lastAssistantDate,
                   let promptDate = Self.parseTimestamp(obj["timestamp"]) {
                    pendingIdleSecs = max(0, Int(promptDate.timeIntervalSince(last)))
                }
                resetTurn()
                return true
            }
            // Tool result: count errors toward the live turn so the chip
            // ribbon can show them, and feed sizes into the waste tracker
            // so we can token-weight the unused-context metric.
            if let message = obj["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                var changed = false
                let errors = content.filter {
                    ($0["type"] as? String) == "tool_result" && ($0["is_error"] as? Bool) == true
                }.count
                if errors > 0 {
                    snapshot.currentTurnErrorCount += errors
                    changed = true
                }
                for blk in content where (blk["type"] as? String) == "tool_result" {
                    guard let id = blk["tool_use_id"] as? String else { continue }
                    waste.recordToolResult(toolUseId: id, content: Self.toolResultText(blk["content"]))
                }
                return changed
            }
            return false
        }

        if type == "system",
           (obj["subtype"] as? String) == "turn_duration" {
            let turnDur = (obj["durationMs"] as? Int)
                ?? (obj["durationMs"] as? Double).map(Int.init)
            snapshot.lastTurnDurationMs = turnDur
            snapshot.lastTurnToolCount = currentTurnTools
            snapshot.lastTurnErrorCount = snapshot.currentTurnErrorCount
            // Turn ended; the next user prompt will reset the trace fully.
            // Keep `latestText` and `recentTexts` so the idle-grace UI can
            // still show the last response.
            snapshot.currentTurnStart = nil
            currentTurnTools = 0
            snapshot.currentTurnErrorCount = 0
            return true
        }

        guard type == "assistant",
              let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else {
            return false
        }

        var changed = false

        // Tool count for the live turn.
        let toolUses = content.filter { ($0["type"] as? String) == "tool_use" }.count
        if toolUses > 0 {
            currentTurnTools += toolUses
            changed = true
        }

        if let text = Self.extractTextOnly(content), !text.isEmpty {
            snapshot.latestText = text
            appendRecentText(text)
            changed = true
        }

        if let date = Self.parseTimestamp(obj["timestamp"]) {
            lastAssistantDate = date
        }

        if let id = message["id"] as? String,
           let usage = Self.parseUsage(message["usage"]),
           !seenMessageIds.contains(id) {
            seenMessageIds.insert(id)
            let cost = LLMPricing.turnCost(usage)
            snapshot.lastTurnCost = cost
            snapshot.lastTurnPromptTokens = usage.promptTokens
            snapshot.lastTurnIdleSecsBefore = pendingIdleSecs
            pendingIdleSecs = nil
            snapshot.sessionTotalCost += cost.total
            snapshot.sessionReclaimableCost += cost.cacheCreate
            snapshot.sessionUniqueRequests += 1

            assistantTurnCounter += 1
            // Scan this request's text + tool_use args for references to
            // *prior* artifacts before recording any new ones; the tracker's
            // turnIdx filter prevents same-turn self-matches but ordering
            // makes the intent obvious.
            waste.scanReferences(turnIdx: assistantTurnCounter, haystack: Self.haystack(content))
            for blk in content where (blk["type"] as? String) == "tool_use" {
                let name = (blk["name"] as? String) ?? ""
                guard let id = blk["id"] as? String,
                      let input = blk["input"] as? [String: Any] else { continue }
                waste.recordToolUse(turnIdx: assistantTurnCounter, toolUseId: id, name: name, input: input)
            }
            if let summary = waste.summary(currentTurnIdx: assistantTurnCounter) {
                snapshot.contextUnusedPct = summary.unusedPct
                snapshot.contextTrackedTokens = summary.totalTokens
                snapshot.contextUnusedTokens = summary.unusedTokens
                snapshot.contextDeadArtifacts = waste.topDeadArtifacts(
                    currentTurnIdx: assistantTurnCounter
                ).map {
                    TranscriptSnapshot.DeadArtifactEntry(
                        key: $0.key, tool: $0.tool, estTokens: $0.estTokens
                    )
                }
            }
            changed = true
        }

        return changed
    }

    /// Concatenate text blocks and JSON-encoded tool_use input fields. This
    /// is the haystack ContextWasteTracker scans against — anything the model
    /// emits in this request that could "use" a previously-loaded artifact.
    private static func haystack(_ content: [[String: Any]]) -> String {
        var parts: [String] = []
        for blk in content {
            switch blk["type"] as? String {
            case "text":
                if let t = blk["text"] as? String { parts.append(t) }
            case "thinking":
                if let t = blk["thinking"] as? String { parts.append(t) }
            case "tool_use":
                if let input = blk["input"],
                   let data = try? JSONSerialization.data(withJSONObject: input),
                   let s = String(data: data, encoding: .utf8) {
                    parts.append(s)
                }
            default:
                break
            }
        }
        return parts.joined(separator: "\n")
    }

    /// Best-effort text extraction for a tool_result `content` field,
    /// which can be a plain string or an array of `{type:"text",
    /// text:"..."}` blocks. Used for token estimation (chars/4) and
    /// symbol extraction in `ContextWasteTracker.recordToolResult`.
    private static func toolResultText(_ raw: Any?) -> String {
        if let s = raw as? String { return s }
        if let arr = raw as? [[String: Any]] {
            var parts: [String] = []
            for blk in arr where (blk["type"] as? String) == "text" {
                if let t = blk["text"] as? String { parts.append(t) }
            }
            return parts.joined(separator: "\n")
        }
        return ""
    }

    private static func parseTimestamp(_ raw: Any?) -> Date? {
        guard let s = raw as? String, !s.isEmpty else { return nil }
        return isoFormatter.date(from: s)
    }

    private static func parseUsage(_ raw: Any?) -> LLMUsage? {
        guard let dict = raw as? [String: Any] else { return nil }
        func intVal(_ key: String) -> Int {
            if let i = dict[key] as? Int { return i }
            if let d = dict[key] as? Double { return Int(d) }
            return 0
        }
        let usage = LLMUsage(
            inputTokens: intVal("input_tokens"),
            cacheReadTokens: intVal("cache_read_input_tokens"),
            cacheCreationTokens: intVal("cache_creation_input_tokens"),
            outputTokens: intVal("output_tokens")
        )
        // Skip fully-empty usage rows (e.g., synthetic entries) — they'd
        // pollute the unique-request counter.
        if usage.promptTokens == 0 && usage.outputTokens == 0 { return nil }
        return usage
    }

    /// New user prompt: clear the assistant trace, start the live turn clock,
    /// reset live-turn counters.
    private func resetTurn() {
        snapshot.latestText = nil
        snapshot.recentTexts = []
        snapshot.currentTurnStart = Date()
        snapshot.currentTurnErrorCount = 0
        currentTurnTools = 0
    }

    /// Append to `recentTexts`, deduping against the immediately previous
    /// entry to absorb back-to-back duplicates from streaming.
    private func appendRecentText(_ text: String) {
        guard snapshot.recentTexts.last != text else { return }
        snapshot.recentTexts.append(text)
        if snapshot.recentTexts.count > Self.recentTextLimit {
            snapshot.recentTexts.removeFirst(snapshot.recentTexts.count - Self.recentTextLimit)
        }
    }

    /// If the user-message payload is a `<task-notification>` XML blob,
    /// return its `<summary>` (e.g. `Background command "X" completed (exit
    /// code 0)`) so the sidebar can show the same thing the TUI prints when
    /// a background task finishes.
    private static func extractTaskNotificationSummary(_ obj: [String: Any]) -> String? {
        guard let message = obj["message"] as? [String: Any],
              let raw = message["content"] as? String,
              raw.contains("<task-notification>") else { return nil }
        guard let start = raw.range(of: "<summary>"),
              let end = raw.range(of: "</summary>", range: start.upperBound..<raw.endIndex) else {
            return nil
        }
        let summary = String(raw[start.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? nil : summary
    }

    private static func extractTextOnly(_ content: [[String: Any]]) -> String? {
        let texts = content.compactMap { block -> String? in
            guard (block["type"] as? String) == "text" else { return nil }
            return block["text"] as? String
        }
        let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private static func isUserPrompt(_ obj: [String: Any]) -> Bool {
        guard let message = obj["message"] as? [String: Any] else { return false }
        if message["content"] is String { return true }
        if let content = message["content"] as? [[String: Any]] {
            let hasToolResult = content.contains { ($0["type"] as? String) == "tool_result" }
            return !hasToolResult
        }
        return false
    }
}
