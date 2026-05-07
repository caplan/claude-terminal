import AppKit
import Combine

struct SessionEntry: Identifiable {
    let id: UUID
    let sessionName: String
    let workingDirectory: String
    let status: SessionStatus
    let modelName: String?
    let conversationTurns: Int?
    let costUsd: Double?
    let lastUpdate: Date
    let isActive: Bool
}

final class SessionListViewModel: ObservableObject {
    @Published var sessions: [SessionEntry] = []

    private var cancellables = Set<AnyCancellable>()
    private var monitorCancellables = Set<AnyCancellable>()
    private var isListening = false

    func refresh() {
        rebuildSessions()
        startListening()
    }

    func stopListening() {
        monitorCancellables.removeAll()
        cancellables.removeAll()
        isListening = false
    }

    private func startListening() {
        guard !isListening else { return }
        isListening = true

        NotificationCenter.default.publisher(for: .sessionListDidChange)
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildSessions() }
            .store(in: &cancellables)

        subscribeToMonitors()
    }

    private func subscribeToMonitors() {
        monitorCancellables.removeAll()
        guard let snapshots = AppDelegate.shared?.activeSessionSnapshots() else { return }
        for (_, monitor) in snapshots {
            monitor.$state
                .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
                .sink { [weak self] _ in self?.rebuildSessions() }
                .store(in: &monitorCancellables)
        }
    }

    private func rebuildSessions() {
        let active = buildActiveSessions()
        let activeIds = Set(active.compactMap { entry -> UUID? in
            guard let snapshots = AppDelegate.shared?.activeSessionSnapshots() else { return nil }
            return snapshots.first(where: { $0.windowId == entry.id })?.monitor.sessionId
        })
        let activeDirs = Set(active.map(\.workingDirectory))

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let past = Self.scanPastSessions(excludingIds: activeIds, excludingDirs: activeDirs)
            DispatchQueue.main.async {
                let all = active + past
                self?.sessions = all.sorted { $0.lastUpdate > $1.lastUpdate }
            }
        }
    }

    private func buildActiveSessions() -> [SessionEntry] {
        guard let snapshots = AppDelegate.shared?.activeSessionSnapshots() else { return [] }
        return snapshots.map { (windowId, monitor) in
            let state = monitor.state
            return SessionEntry(
                id: windowId,
                sessionName: state.sessionName ?? (state.workingDirectory as NSString?)?.lastPathComponent ?? "Session",
                workingDirectory: state.workingDirectory ?? "",
                status: state.status,
                modelName: state.modelName,
                conversationTurns: state.conversationTurns,
                costUsd: state.cost?.totalCostUsd,
                lastUpdate: Date(),
                isActive: true
            )
        }
    }

    private static func scanPastSessions(excludingIds activeIds: Set<UUID>, excludingDirs activeDirs: Set<String>) -> [SessionEntry] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let sessionsDir = "\(home)/.claude-terminal/sessions"

        guard let uuidStrings = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return [] }

        let hidden = Set(UserDefaults.standard.stringArray(forKey: "hiddenSessionDirs") ?? [])

        var candidates: [SessionEntry] = []
        for uuidStr in uuidStrings {
            guard let uuid = UUID(uuidString: uuidStr) else { continue }
            guard !activeIds.contains(uuid) else { continue }

            let statusPath = "\(sessionsDir)/\(uuidStr)/status.json"
            guard let data = fm.contents(atPath: statusPath),
                  let state = try? JSONDecoder().decode(SessionState.self, from: data),
                  let attrs = try? fm.attributesOfItem(atPath: statusPath),
                  let modDate = attrs[.modificationDate] as? Date else { continue }

            let dir = state.workingDirectory ?? ""
            guard !dir.isEmpty else { continue }
            guard !activeDirs.contains(dir) else { continue }
            guard !hidden.contains(dir) else { continue }

            candidates.append(SessionEntry(
                id: uuid,
                sessionName: state.sessionName ?? (dir as NSString).lastPathComponent,
                workingDirectory: dir,
                status: state.status,
                modelName: state.modelName,
                conversationTurns: state.conversationTurns,
                costUsd: state.cost?.totalCostUsd,
                lastUpdate: modDate,
                isActive: false
            ))
        }

        var byDir: [String: SessionEntry] = [:]
        for c in candidates {
            if let existing = byDir[c.workingDirectory] {
                if c.lastUpdate > existing.lastUpdate {
                    byDir[c.workingDirectory] = c
                }
            } else {
                byDir[c.workingDirectory] = c
            }
        }

        return byDir.values.sorted { $0.lastUpdate > $1.lastUpdate }
    }
}
