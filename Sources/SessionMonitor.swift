import AppKit
import Combine
import UserNotifications

final class SessionMonitor: ObservableObject {
    @Published var state: SessionState = .empty

    let sessionId: UUID
    private let statusFilePath: String
    private let isMock: Bool
    private let workingDirectory: String?
    private var overriddenName: String?

    private var fileDescriptor: Int32 = -1
    private var dispatchSource: DispatchSourceFileSystemObject?
    private var retryTimer: DispatchSourceTimer?
    private var pollTimer: DispatchSourceTimer?
    private let watchQueue = DispatchQueue(label: "org.claire.claude-terminal.session-monitor", qos: .utility)

    init(sessionId: UUID, initialName: String? = nil, workingDirectory: String? = nil) {
        self.sessionId = sessionId
        self.isMock = false
        self.workingDirectory = workingDirectory
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.statusFilePath = "\(home)/.claude-terminal/sessions/\(sessionId.uuidString)/status.json"
        var initial = SessionState.empty
        if let workingDirectory {
            initial.workingDirectory = workingDirectory
            if let saved = UserDefaults.standard.string(forKey: "sessionName-\(workingDirectory)") {
                initial.sessionName = saved
                self.overriddenName = saved
            } else if let initialName {
                initial.sessionName = initialName
            }
        } else if let initialName {
            initial.sessionName = initialName
        }
        if initial != .empty {
            _state = Published(initialValue: initial)
        }
    }

    private init(mockState: SessionState) {
        self.sessionId = UUID()
        self.isMock = true
        self.statusFilePath = ""
        self.workingDirectory = nil
        self.state = mockState
    }

    static func mock() -> SessionMonitor {
        let state = SessionState(
            sessionName: "sidebar-feature",
            modelName: "Claude Opus 4.6",
            status: .thinking,
            contextUsage: ContextUsage(
                usedPercentage: 21,
                remainingPercentage: 79,
                contextWindowSize: 200_000,
                totalInputTokens: 42_000,
                totalOutputTokens: 8_500,
                cacheReadTokens: 12_000,
                cacheCreationTokens: 5_000
            ),
            cost: CostInfo(
                totalCostUsd: 0.0847,
                totalDurationMs: 185_000,
                totalApiDurationMs: 23_400,
                totalLinesAdded: 156,
                totalLinesRemoved: 23
            ),
            currentToolName: "Read",
            toolDetail: "Sources/SidebarView.swift",
            subagents: [
                SubagentInfo(id: "1", name: "Explore", status: .streaming, description: "Searching codebase"),
                SubagentInfo(id: "2", name: "Plan", status: .idle, description: "Waiting"),
            ],
            tasks: [
                SessionTask(id: "1", subject: "Create data model", status: "completed"),
                SessionTask(id: "2", subject: "Implement file watcher", status: "in_progress"),
                SessionTask(id: "3", subject: "Build sidebar UI", status: "pending"),
            ],
            conversationTurns: 7
        )
        return SessionMonitor(mockState: state)
    }

    func removeSubagent(_ agentId: String) {
        state.subagents.removeAll { $0.id == agentId }
        guard !isMock else { return }
        let dir = (statusFilePath as NSString).deletingLastPathComponent
        let hiddenFile = dir + "/hidden-agents"
        watchQueue.async {
            let existing = (try? String(contentsOfFile: hiddenFile, encoding: .utf8)) ?? ""
            var ids = Set(existing.split(separator: "\n").map(String.init))
            ids.insert(agentId)
            try? ids.joined(separator: "\n").write(toFile: hiddenFile, atomically: true, encoding: .utf8)
        }
    }

    func resetCost() {
        let zero = CostInfo(totalCostUsd: 0, totalDurationMs: 0, totalApiDurationMs: 0, totalLinesAdded: 0, totalLinesRemoved: 0)
        // Set baseline to the negative of the current displayed total so that on the
        // next statusline poll, displayed = reported + baseline cancels out the cost
        // already accumulated in the current process.
        let current = state.cost ?? zero
        let previousBaseline = state.costBaseline ?? zero
        state.costBaseline = CostInfo(
            totalCostUsd: previousBaseline.totalCostUsd - current.totalCostUsd,
            totalDurationMs: previousBaseline.totalDurationMs - current.totalDurationMs,
            totalApiDurationMs: previousBaseline.totalApiDurationMs - current.totalApiDurationMs,
            totalLinesAdded: previousBaseline.totalLinesAdded - current.totalLinesAdded,
            totalLinesRemoved: previousBaseline.totalLinesRemoved - current.totalLinesRemoved
        )
        state.cost = zero
        guard !isMock else { return }
        writeState()
        // Clear the persisted running total for this Claude Code session so a reopen
        // also starts at zero.
        if let cc = state.claudeCodeSessionId {
            watchQueue.async {
                let persistPath = NSString(string: "~/.claude-terminal/cost-by-session.json").expandingTildeInPath
                var map: [String: Any] = [:]
                if let data = FileManager.default.contents(atPath: persistPath),
                   let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    map = parsed
                }
                map[cc] = [
                    "totalCostUsd": 0,
                    "totalDurationMs": 0,
                    "totalApiDurationMs": 0,
                    "totalLinesAdded": 0,
                    "totalLinesRemoved": 0
                ]
                let dir = (persistPath as NSString).deletingLastPathComponent
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                if let data = try? JSONSerialization.data(withJSONObject: map) {
                    try? data.write(to: URL(fileURLWithPath: persistPath), options: .atomic)
                }
            }
        }
    }

    func renameSession(_ name: String?) {
        overriddenName = name
        state.sessionName = name
        if let dir = workingDirectory {
            if let name {
                UserDefaults.standard.set(name, forKey: "sessionName-\(dir)")
            } else {
                UserDefaults.standard.removeObject(forKey: "sessionName-\(dir)")
            }
        }
        guard !isMock else { return }
        writeState()
    }

    func startMonitoring() {
        guard !isMock else { return }
        ensureDirectoryExists()
        if state.sessionName != nil {
            writeState()
        }
        attemptWatch()
        startPollTimer()
    }

    func stopMonitoring() {
        guard !isMock else { return }
        retryTimer?.cancel()
        retryTimer = nil
        pollTimer?.cancel()
        pollTimer = nil
        dispatchSource?.cancel()
        dispatchSource = nil
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    private func startPollTimer() {
        let timer = DispatchSource.makeTimerSource(queue: watchQueue)
        timer.schedule(deadline: .now() + 2.0, repeating: 2.0)
        timer.setEventHandler { [weak self] in
            self?.readAndDecode()
        }
        timer.resume()
        pollTimer = timer
    }

    deinit {
        stopMonitoring()
    }

    // MARK: - Private

    private func writeState() {
        watchQueue.async { [weak self] in
            guard let self else { return }
            guard let data = try? JSONEncoder().encode(self.state) else { return }
            let dir = (self.statusFilePath as NSString).deletingLastPathComponent
            let tmp = dir + "/.status.json.tmp"
            try? data.write(to: URL(fileURLWithPath: tmp))
            try? FileManager.default.moveItem(atPath: tmp, toPath: self.statusFilePath)
        }
    }

    private func ensureDirectoryExists() {
        let dir = (statusFilePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    private func attemptWatch() {
        let fd = open(statusFilePath, O_EVTONLY)
        if fd < 0 {
            scheduleRetry()
            return
        }
        fileDescriptor = fd
        readAndDecode()
        startDispatchSource(fd: fd)
    }

    private func startDispatchSource(fd: Int32) {
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = source.data
            if event.contains(.rename) || event.contains(.delete) {
                self.handleFileRemoved()
            } else if event.contains(.write) {
                self.readAndDecode()
            }
        }

        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fileDescriptor >= 0 {
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }

        source.resume()
        dispatchSource = source
    }

    private func handleFileRemoved() {
        dispatchSource?.cancel()
        dispatchSource = nil
        fileDescriptor = -1
        watchQueue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.attemptWatch()
        }
    }

    private func scheduleRetry() {
        let timer = DispatchSource.makeTimerSource(queue: watchQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let fd = open(self.statusFilePath, O_EVTONLY)
            if fd >= 0 {
                self.retryTimer?.cancel()
                self.retryTimer = nil
                self.fileDescriptor = fd
                self.readAndDecode()
                self.startDispatchSource(fd: fd)
            }
        }
        timer.resume()
        retryTimer = timer
    }

    private func readAndDecode() {
        watchQueue.async { [weak self] in
            guard let self else { return }
            guard let data = FileManager.default.contents(atPath: self.statusFilePath) else { return }
            guard var decoded = try? JSONDecoder().decode(SessionState.self, from: data) else { return }
            DispatchQueue.main.async {
                let wasNeeding = self.state.needsInput ?? false

                if decoded.workingDirectory == nil {
                    decoded.workingDirectory = self.state.workingDirectory
                }
                if let name = self.overriddenName {
                    decoded.sessionName = name
                }

                self.state = decoded
                if decoded.needsInput == true && !wasNeeding {
                    self.sendNeedsInputNotification()
                }
            }
        }
    }

    private func sendNeedsInputNotification() {
        guard UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true else { return }
        guard !NSApp.isActive else { return }

        let content = UNMutableNotificationContent()
        content.title = state.sessionName ?? "Claude Code"
        content.body = "Needs your attention"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "claude-terminal-\(sessionId.uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
