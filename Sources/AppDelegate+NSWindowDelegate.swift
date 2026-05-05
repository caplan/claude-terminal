import AppKit

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else { return }
        if let windowId = windows.first(where: { $0.value === closingWindow })?.key {
            // Clean up this window's session dir — it's keyed by a per-window
            // UUID and has no reason to persist across closes.
            if let monitor = sessionMonitors[windowId] {
                monitor.stopMonitoring()
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                let sessionDir = "\(home)/.claude-terminal/sessions/\(monitor.sessionId.uuidString)"
                try? FileManager.default.removeItem(atPath: sessionDir)
            }
            sidebarStates.removeValue(forKey: windowId)
            sessionMonitors.removeValue(forKey: windowId)
            documentTabStates.removeValue(forKey: windowId)
            windowConfigs.removeValue(forKey: windowId)
        }
        windows = windows.filter { $0.value !== closingWindow }
        tabManagers = tabManagers.filter { $0.value.window !== closingWindow }
        NotificationCenter.default.post(name: .sessionListDidChange, object: nil)
    }
}
