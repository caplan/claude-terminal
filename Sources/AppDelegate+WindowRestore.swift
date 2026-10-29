import AppKit

extension AppDelegate {
    /// Snapshot every open window into UserDefaults so the next launch can
    /// reopen it: each session in tab order with its name and open docs (with
    /// per-tab scroll positions), the active tab, and the sidebar settings.
    func saveWindowConfigs() {
        var snapshots: [WindowSnapshot] = []
        for (windowId, _) in windows {
            guard let windowTabs = windowSessions[windowId] else { continue }
            var configs: [SessionConfig] = []
            for sessionId in windowTabs.sessionIds {
                guard let record = sessions[sessionId] else { continue }
                var config = record.config
                config.sessionName = record.monitor.state.sessionName
                let tabState = record.tabState
                config.openDocs = tabState.tabs.map { tab in
                    OpenDocState(
                        path: tab.path,
                        scrollY: tabState.liveScroll[tab.id] ?? 0
                    )
                }
                config.activeDocPath = tabState.active.flatMap { id in
                    tabState.tabs.first(where: { $0.id == id })?.path
                }
                config.customBackgroundHex = customTerminalBackgrounds[sessionId]?.hexString()
                configs.append(config)
            }
            guard !configs.isEmpty else { continue }
            let activeIndex = windowTabs.activeSessionId
                .flatMap { windowTabs.sessionIds.firstIndex(of: $0) } ?? 0
            let sidebar = sidebarStates[windowId]
            snapshots.append(WindowSnapshot(
                sessions: configs,
                activeIndex: activeIndex,
                sidebarVisible: sidebar?.isVisible ?? true,
                sidebarWidth: sidebar.map { Double($0.width) },
                railWidth: Double(windowTabs.railWidth)
            ))
        }
        if let data = try? JSONEncoder().encode(snapshots) {
            UserDefaults.standard.set(data, forKey: "savedWindows")
        }
    }

    /// Returns the saved-windows array if present, then clears it — so a
    /// crash on launch can't loop us through the same broken restore. Reads
    /// the current format first and falls back to the one-session-per-window
    /// format older builds wrote.
    func restoreSavedWindows() -> [WindowSnapshot]? {
        guard let data = UserDefaults.standard.data(forKey: "savedWindows") else { return nil }
        UserDefaults.standard.removeObject(forKey: "savedWindows")
        if let snapshots = try? JSONDecoder().decode([WindowSnapshot].self, from: data) {
            return snapshots
        }
        if let legacy = try? JSONDecoder().decode([WindowConfig].self, from: data) {
            return legacy.map { WindowSnapshot(legacy: $0) }
        }
        return nil
    }

    /// Reopens one saved window with every session as a tab, in saved order.
    /// Every session resumes with `--continue`.
    func restoreWindow(snapshot: WindowSnapshot) {
        guard !snapshot.sessions.isEmpty else { return }
        let windowId = createWindow(
            sidebarVisible: snapshot.sidebarVisible,
            sidebarWidth: snapshot.sidebarWidth.map { CGFloat($0) },
            railWidth: snapshot.railWidth.map { CGFloat($0) }
        )
        var restoredIds: [UUID] = []
        for config in snapshot.sessions {
            guard let sessionId = addSession(
                to: windowId,
                workingDirectory: config.workingDirectory,
                claudeOptions: Self.continueOptions(config.claudeOptions),
                sessionName: config.sessionName,
                storedConfig: config,
                activate: false
            ) else { continue }
            restoreDocTabs(from: config, sessionId: sessionId)
            restoredIds.append(sessionId)
        }
        guard !restoredIds.isEmpty else { return }
        let index = min(max(snapshot.activeIndex, 0), restoredIds.count - 1)
        activateSession(restoredIds[index])
    }

    /// Adds `--continue` to a saved option string if it is not there yet.
    static func continueOptions(_ saved: String?) -> String {
        var opts = saved ?? ""
        if !opts.contains("--continue") {
            opts = opts.isEmpty ? "--continue" : "--continue \(opts)"
        }
        return opts
    }

    /// Reopen the markdown and image tabs that were open when the app last
    /// quit, and prime the pending-scroll map so the first render of each
    /// doc restores its previous scrollY.
    func restoreDocTabs(from config: SessionConfig, sessionId: UUID) {
        guard let tabState = sessions[sessionId]?.tabState,
              let saved = config.openDocs, !saved.isEmpty else { return }
        for doc in saved where FileManager.default.fileExists(atPath: doc.path) {
            tabState.pendingRestore[doc.path] = doc.scrollY
            tabState.open(path: doc.path)
        }
        if let activePath = config.activeDocPath,
           let match = tabState.tabs.first(where: { $0.path == activePath }) {
            tabState.active = match.id
        } else {
            tabState.active = nil
        }
    }
}
