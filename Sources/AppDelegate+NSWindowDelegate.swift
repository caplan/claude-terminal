import AppKit

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else { return }
        if let windowId = windows.first(where: { $0.value === closingWindow })?.key {
            // Stop watching the status file, but leave the session dir on
            // disk so the menubar popover can surface it as a past session.
            // Launch-time pruning (AppDelegate+Pruning.swift) caps retention.
            sessionMonitors[windowId]?.stopMonitoring()
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
