import AppKit
import SwiftUI

/// Window and session lifecycle. A window is created empty and sessions are
/// added to it as tabs. One window holds one or more sessions; one session
/// belongs to exactly one window.
extension AppDelegate {
    // MARK: - Windows

    /// Creates an empty window: its NSWindow, sidebar state and tab list. It
    /// stays off screen until `addSession` gives it a first session.
    @discardableResult
    func createWindow(sidebarVisible: Bool, sidebarWidth: CGFloat? = nil, railWidth: CGFloat? = nil) -> UUID {
        let windowId = UUID()
        let sidebarState = SidebarState(defaultVisible: sidebarVisible, width: sidebarWidth)
        let windowTabs = WindowSessions(windowId: windowId, railWidth: railWidth)

        let window = ClaudeTerminalWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.windowId = windowId
        window.minSize = NSSize(width: 600, height: 300)
        window.contentMinSize = NSSize(width: 600, height: 300)

        // An AppKit container with two NSHostingViews (tab bar, sessions),
        // each with an explicit frame; see WindowContentView for why.
        window.contentView = WindowContentView(
            sessions: windowTabs,
            sidebarState: sidebarState,
            frame: NSRect(x: 0, y: 0, width: 1080, height: 600)
        )
        window.isReleasedWhenClosed = false
        window.delegate = self

        windows[windowId] = window
        sidebarStates[windowId] = sidebarState
        windowSessions[windowId] = windowTabs
        return windowId
    }

    /// Creates a window holding one session: the path every "new session"
    /// entry point takes.
    @discardableResult
    func openWindow(
        workingDirectory dir: String,
        claudeOptions opts: String?,
        sessionName: String?,
        sidebarVisible: Bool,
        sidebarWidth: CGFloat? = nil,
        railWidth: CGFloat? = nil,
        storedConfig: SessionConfig? = nil
    ) -> (windowId: UUID, sessionId: UUID?) {
        let windowId = createWindow(sidebarVisible: sidebarVisible, sidebarWidth: sidebarWidth, railWidth: railWidth)
        let sessionId = addSession(
            to: windowId,
            workingDirectory: dir,
            claudeOptions: opts,
            sessionName: sessionName,
            storedConfig: storedConfig
        )
        return (windowId, sessionId)
    }

    // MARK: - Sessions

    /// Adds a session to a window as its last tab. The first session of a
    /// window sets the frame-autosave key and shows the window.
    @discardableResult
    func addSession(
        to windowId: UUID,
        workingDirectory dir: String,
        claudeOptions opts: String?,
        sessionName: String?,
        storedConfig: SessionConfig? = nil,
        activate: Bool = true
    ) -> UUID? {
        guard let window = windows[windowId], let windowTabs = windowSessions[windowId] else { return nil }
        let resolvedName = sessionName ?? (dir as NSString).lastPathComponent
        let record = makeSessionRecord(workingDirectory: dir, claudeOptions: opts, sessionName: resolvedName, storedConfig: storedConfig)
        registerSession(record, in: window)

        let isFirst = windowTabs.sessionIds.isEmpty
        windowTabs.sessionIds.append(record.sessionId)
        if isFirst {
            // The autosave key follows the first session and stays put when
            // the active tab changes, so the frame does not jump on a switch.
            window.setFrameAutosaveName("claude-terminal-\(resolvedName)")
            if !window.setFrameUsingName(window.frameAutosaveName) {
                window.center()
            }
        }
        if activate || isFirst {
            activateSession(record.sessionId)
        }
        if isFirst {
            window.makeKeyAndOrderFront(nil)
        }
        NotificationCenter.default.post(name: .sessionListDidChange, object: nil)
        print("[claude-terminal] Window \(windowId) session \(record.sessionId) (dir \(dir), opts: \(opts ?? "none"))")
        return record.sessionId
    }

    /// Brings a session to the front of its window: the tab list, the window
    /// title and keyboard focus. The portal spike showed that focus does not
    /// follow the swap on its own, so the first responder is set by hand.
    func activateSession(_ sessionId: UUID) {
        guard let windowId = windowId(forSession: sessionId),
              let window = windows[windowId],
              let windowTabs = windowSessions[windowId],
              let record = sessions[sessionId] else { return }
        if windowTabs.activeSessionId != sessionId {
            withAnimation(.easeInOut(duration: 0.15)) {
                windowTabs.activeSessionId = sessionId
            }
        }
        window.title = record.monitor.state.sessionName
            ?? (record.config.workingDirectory as NSString).lastPathComponent
        // The session's ContentView mounts on the next run-loop turn, and a
        // fresh tab's Metal view a few turns after that. Poll briefly.
        focusTerminalWhenReady(sessionId: sessionId, windowId: windowId, attemptsRemaining: 20)
        NotificationCenter.default.post(name: .sessionListDidChange, object: nil)
    }

    private func focusTerminalWhenReady(sessionId: UUID, windowId: UUID, attemptsRemaining: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self,
                  let window = self.windows[windowId],
                  let record = self.sessions[sessionId],
                  self.windowSessions[windowId]?.activeSessionId == sessionId else { return }
            let hosted = record.surface.hostedView
            let ready = record.tabState.active != nil
                || (hosted.window === window && self.firstDescendant(of: hosted, ofType: GhosttyNSView.self) != nil)
            if ready {
                self.focusTerminal(of: record, in: window)
            } else if attemptsRemaining > 0 {
                self.focusTerminalWhenReady(sessionId: sessionId, windowId: windowId, attemptsRemaining: attemptsRemaining - 1)
            }
        }
    }

    /// Puts keyboard focus on a session's terminal, or on the window's content
    /// view when a doc tab covers the terminal (the doc find bar expects that).
    func focusTerminal(of record: SessionRecord, in window: NSWindow) {
        guard record.tabState.active == nil else {
            window.makeFirstResponder(sessionsHostView(of: window))
            return
        }
        // The Metal view, not the scroll view around it: the vendored
        // performKeyEquivalent acts only when the first responder is inside
        // GhosttyNSView.
        if let surfaceView = firstDescendant(of: record.surface.hostedView, ofType: GhosttyNSView.self) {
            window.makeFirstResponder(surfaceView)
        } else {
            window.makeFirstResponder(record.surface.hostedView)
        }
    }

    /// Closes one tab. The last tab closes its window, and `windowWillClose`
    /// then tears the session down. Otherwise the neighbor to the right (or
    /// to the left, at the end of the row) becomes active.
    func closeSession(_ sessionId: UUID) {
        guard let windowId = windowId(forSession: sessionId),
              let windowTabs = windowSessions[windowId],
              let index = windowTabs.sessionIds.firstIndex(of: sessionId) else { return }
        if windowTabs.sessionIds.count == 1 {
            windows[windowId]?.close()
            return
        }
        let wasActive = windowTabs.activeSessionId == sessionId
        windowTabs.sessionIds.remove(at: index)
        if wasActive {
            activateSession(windowTabs.sessionIds[min(index, windowTabs.sessionIds.count - 1)])
        }
        // Let SwiftUI unmount the tab's ContentView before the surface behind
        // it goes away.
        DispatchQueue.main.async { [weak self] in
            self?.unregisterSession(sessionId)
            NotificationCenter.default.post(name: .sessionListDidChange, object: nil)
        }
    }

    /// Ghostty reports a clean exit of the child process by surface (tab) id.
    func closeSession(forTab tabId: UUID) {
        guard let sessionId = sessionIdForTab[tabId] else { return }
        closeSession(sessionId)
    }

    /// Closes every other tab of the window and leaves `sessionId` active.
    func closeOtherSessions(in windowId: UUID, keeping sessionId: UUID) {
        guard let ids = windowSessions[windowId]?.sessionIds, ids.contains(sessionId) else { return }
        activateSession(sessionId)
        for other in ids where other != sessionId {
            closeSession(other)
        }
    }

    /// Whether the window shows the session tab bar right now. The window's
    /// right-click routing uses it to leave the bar's strip to the chips.
    func tabBarIsVisible(in windowId: UUID) -> Bool {
        (windows[windowId]?.contentView as? WindowContentView)?.isTabBarVisible ?? false
    }

    /// The hosting view that holds the session views: the first responder to
    /// use when a doc tab, not the terminal, should take the keyboard.
    func sessionsHostView(of window: NSWindow) -> NSView? {
        (window.contentView as? WindowContentView)?.sessionsHost ?? window.contentView
    }

    /// Moves one tab into a window of its own. The TerminalSurface is the same
    /// object; the portal re-binds it when the new window's ContentView mounts.
    func moveSessionToNewWindow(_ sessionId: UUID) {
        guard let oldWindowId = windowId(forSession: sessionId),
              let oldTabs = windowSessions[oldWindowId],
              oldTabs.sessionIds.count > 1,
              let oldWindow = windows[oldWindowId],
              let oldSidebar = sidebarStates[oldWindowId],
              let record = sessions[sessionId],
              let index = oldTabs.sessionIds.firstIndex(of: sessionId) else { return }

        oldTabs.sessionIds.remove(at: index)
        if oldTabs.activeSessionId == sessionId {
            activateSession(oldTabs.sessionIds[min(index, oldTabs.sessionIds.count - 1)])
        }

        let newWindowId = createWindow(sidebarVisible: oldSidebar.isVisible, sidebarWidth: oldSidebar.width, railWidth: oldTabs.railWidth)
        guard let newWindow = windows[newWindowId], let newTabs = windowSessions[newWindowId] else { return }
        tabManagers[record.tabId] = TabManager(window: newWindow, tabId: record.tabId)
        let name = record.monitor.state.sessionName
            ?? (record.config.workingDirectory as NSString).lastPathComponent
        newWindow.setFrameAutosaveName("claude-terminal-\(name)")
        if !newWindow.setFrameUsingName(newWindow.frameAutosaveName) {
            newWindow.setFrame(oldWindow.frame.offsetBy(dx: 40, dy: -40), display: false)
        }
        newTabs.sessionIds = [sessionId]
        activateSession(sessionId)
        newWindow.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .sessionListDidChange, object: nil)
    }
}
