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

    static let empty = TranscriptSnapshot(
        latestText: nil,
        recentTexts: [],
        lastTurnDurationMs: nil,
        lastTurnToolCount: nil,
        lastTurnErrorCount: nil,
        currentTurnErrorCount: 0,
        currentTurnStart: nil
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
    private static let recentTextLimit = 3

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
                resetTurn()
                return true
            }
            // Tool result: count errors toward the live turn so the chip
            // ribbon can show them.
            if let message = obj["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                let errors = content.filter {
                    ($0["type"] as? String) == "tool_result" && ($0["is_error"] as? Bool) == true
                }.count
                if errors > 0 {
                    snapshot.currentTurnErrorCount += errors
                    return true
                }
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

        return changed
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
