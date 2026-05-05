import AppKit

extension AppDelegate {
    /// Snapshot every open window into UserDefaults so the next launch can
    /// reopen them. Captures session name, sidebar visibility/width, and
    /// the open-doc list with per-tab scroll positions.
    func saveWindowConfigs() {
        var configs: [WindowConfig] = []
        for (windowId, _) in windows {
            guard var config = windowConfigs[windowId] else { continue }
            if let monitor = sessionMonitors[windowId] {
                config.sessionName = monitor.state.sessionName
            }
            if let sidebar = sidebarStates[windowId] {
                config.sidebarVisible = sidebar.isVisible
                config.sidebarWidth = Double(sidebar.width)
            }
            if let tabState = documentTabStates[windowId] {
                config.openDocs = tabState.tabs.map { tab in
                    OpenDocState(
                        path: tab.path,
                        scrollY: tabState.liveScroll[tab.id] ?? 0
                    )
                }
                config.activeDocPath = tabState.active.flatMap { id in
                    tabState.tabs.first(where: { $0.id == id })?.path
                }
            }
            configs.append(config)
        }
        if let data = try? JSONEncoder().encode(configs) {
            UserDefaults.standard.set(data, forKey: "savedWindows")
        }
    }

    /// Returns the saved-windows array if present, then clears it — so a
    /// crash on launch can't loop us through the same broken restore.
    func restoreSavedWindows() -> [WindowConfig]? {
        guard let data = UserDefaults.standard.data(forKey: "savedWindows") else { return nil }
        UserDefaults.standard.removeObject(forKey: "savedWindows")
        return try? JSONDecoder().decode([WindowConfig].self, from: data)
    }

    func restoreWindow(config: WindowConfig, claudeOptions: String) {
        let (_, tabState) = installWindow(
            workingDirectory: config.workingDirectory,
            claudeOptions: claudeOptions,
            sessionName: config.sessionName,
            sidebarVisible: config.sidebarVisible,
            sidebarWidth: config.sidebarWidth.map { CGFloat($0) },
            storedConfig: config
        )

        // Reopen markdown tabs that were open when the app last quit, and
        // prime the pending-scroll map so the first render of each doc
        // restores its previous scrollY.
        if let saved = config.openDocs, !saved.isEmpty {
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
}
