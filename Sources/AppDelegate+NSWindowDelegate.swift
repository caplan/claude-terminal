import AppKit

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else { return }
        if let windowId = windows.first(where: { $0.value === closingWindow })?.key {
            // Stop watching each session's status file, but leave the session
            // dirs on disk so the menubar popover can surface them as past
            // sessions. Launch-time pruning (AppDelegate+Pruning.swift) caps
            // retention.
            for sessionId in windowSessions[windowId]?.sessionIds ?? [] {
                unregisterSession(sessionId)
            }
            windowSessions.removeValue(forKey: windowId)
            sidebarStates.removeValue(forKey: windowId)
        }
        windows = windows.filter { $0.value !== closingWindow }
        NotificationCenter.default.post(name: .sessionListDidChange, object: nil)
    }
}
