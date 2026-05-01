import Foundation

/// Watches a Claude Code transcript JSONL file and emits the text content of
/// the most recent `{"type":"assistant"}` entry. Uses DispatchSource to react
/// to file writes, seeking only the new bytes since the last read.
final class TranscriptTailer {
    private let queue = DispatchQueue(label: "org.claire.claude-terminal.transcript", qos: .utility)
    private var fd: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private var retryTimer: DispatchSourceTimer?
    private var offset: UInt64 = 0
    private var lineBuffer = Data()
    private var currentPath: String?
    private let onText: (String) -> Void

    init(onText: @escaping (String) -> Void) {
        self.onText = onText
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
        while idx < lineBuffer.endIndex {
            if lineBuffer[idx] == newline {
                processLine(lineBuffer.subdata(in: start..<idx))
                lastNewline = idx
                start = lineBuffer.index(after: idx)
            }
            idx = lineBuffer.index(after: idx)
        }
        if let lastNewline {
            lineBuffer = lineBuffer.subdata(in: lineBuffer.index(after: lastNewline)..<lineBuffer.endIndex)
        }
    }

    private func processLine(_ data: Data) {
        guard !data.isEmpty else { return }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let type = obj["type"] as? String
        if type == "user" {
            // Claude Code logs tool_result entries as type:"user" with a
            // tool_result content block. Those happen between assistant
            // messages mid-turn — clearing on them would wipe the sidebar
            // headline every tool call. A real user prompt carries a
            // `promptId` and a plain-text / string content, so gate on that.
            if Self.isUserPrompt(obj) {
                onText("")
            }
            return
        }
        guard type == "assistant" else { return }
        if let text = Self.extractAssistantText(obj), !text.isEmpty {
            onText(text)
        }
    }

    private static func isUserPrompt(_ obj: [String: Any]) -> Bool {
        guard let message = obj["message"] as? [String: Any] else { return false }
        // String-form content → always a prompt.
        if message["content"] is String { return true }
        // Array-form content: prompt iff no block is a tool_result.
        if let content = message["content"] as? [[String: Any]] {
            let hasToolResult = content.contains { ($0["type"] as? String) == "tool_result" }
            return !hasToolResult
        }
        return false
    }

    private static func extractAssistantText(_ obj: [String: Any]) -> String? {
        guard let message = obj["message"] as? [String: Any] else { return nil }
        if let content = message["content"] as? [[String: Any]] {
            let texts = content.compactMap { block -> String? in
                guard (block["type"] as? String) == "text" else { return nil }
                return block["text"] as? String
            }
            let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }
        if let text = message["content"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }
}
