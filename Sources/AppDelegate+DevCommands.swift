import AppKit

/// Development instances only: tab commands read from a file, so a check can
/// drive the app without keyboard access. Needs CLAUDE_TERMINAL_DEV_INSTANCE=1
/// plus CLAUDE_TERMINAL_DEV_CMD (the command file, consumed on read) and
/// CLAUDE_TERMINAL_DEV_LOG (where results are appended). See CONTRIBUTING.md.
extension AppDelegate {
    func startDevCommandPollerIfEnabled() {
        let env = ProcessInfo.processInfo.environment
        guard env["CLAUDE_TERMINAL_DEV_INSTANCE"] == "1",
              let path = env["CLAUDE_TERMINAL_DEV_CMD"], !path.isEmpty else { return }
        devLog("dev command poller on: \(path)")
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self,
                  let data = FileManager.default.contents(atPath: path),
                  let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return }
            try? FileManager.default.removeItem(atPath: path)
            for line in text.split(separator: "\n") {
                self.runDevCommand(String(line))
            }
        }
    }

    func devLog(_ line: String) {
        guard let path = ProcessInfo.processInfo.environment["CLAUDE_TERMINAL_DEV_LOG"], !path.isEmpty else { return }
        let data = Data("\(ISO8601DateFormatter().string(from: Date())) \(line)\n".utf8)
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }

    /// Commands: `new-tab <dir> <name> [claude options...]`, `close-tab`,
    /// `next`, `prev`, `activate <index>`, `move-new-window`, `close-window`,
    /// `save` (write the Save & Quit snapshot without quitting), `status`,
    /// `quit`, and for the tab bar and drags: `tabs-left`, `tabs-top`,
    /// `toggle-tab-bar`, `rail-width <n>`, `frame <x> <y> <w> <h>`,
    /// `focus <window>`, `reorder <index>`,
    /// `move-to <window> [index]`, `merge-into <window> [index]` and
    /// `probe <x> <y>` (a window is a prefix of its id in the status report). Every command logs a status report afterwards.
    func runDevCommand(_ line: String) {
        let parts = line.split(separator: " ").map(String.init)
        guard let verb = parts.first else { return }
        devLog("> \(line)")
        switch verb {
        case "new-tab":
            guard parts.count >= 3, let (windowId, _) = resolveFrontWindow() else {
                devLog("new-tab needs <dir> <name> and a front window")
                return
            }
            let opts = parts.count > 3 ? parts[3...].joined(separator: " ") : nil
            addSession(to: windowId, workingDirectory: parts[1], claudeOptions: opts, sessionName: parts[2])
        case "close-tab":
            if let front = frontSession() { closeSession(front.record.sessionId) }
        case "next":
            showNextTab()
        case "prev":
            showPreviousTab()
        case "activate":
            guard parts.count == 2, let index = Int(parts[1]),
                  let (windowId, _) = resolveFrontWindow(),
                  let ids = windowSessions[windowId]?.sessionIds, ids.indices.contains(index) else { return }
            activateSession(ids[index])
        case "move-new-window":
            if let front = frontSession() { moveSessionToNewWindow(front.record.sessionId) }
        case "close-window":
            resolveFrontWindow()?.1.close()
        case "status":
            break
        case "frame":
            // frame <x> <y> <w> <h>: move and size the front window.
            let values = parts.dropFirst().compactMap(Double.init)
            guard values.count == 4, let (_, window) = resolveFrontWindow() else { return }
            window.setFrame(NSRect(x: values[0], y: values[1], width: values[2], height: values[3]), display: true)
        case "focus":
            // focus <window id prefix>: bring that window to the front.
            guard parts.count == 2, let id = devWindow(prefix: parts[1]) else { return }
            windows[id]?.makeKeyAndOrderFront(nil)
        case "tabs-left":
            setTabsOnLeft()
        case "tabs-top":
            setTabsOnTop()
        case "toggle-tab-bar":
            toggleTabBar()
        case "rail-width":
            guard parts.count == 2, let width = Double(parts[1]),
                  let (windowId, _) = resolveFrontWindow() else { return }
            windowSessions[windowId]?.railWidth = CGFloat(width)
        case "reorder":
            guard parts.count == 2, let index = Int(parts[1]), let front = frontSession() else { return }
            reorderSession(front.record.sessionId, to: index)
        case "move-to":
            // move-to <window id prefix> [index]: the front tab joins that window.
            guard parts.count >= 2, let front = frontSession(),
                  let target = devWindow(prefix: parts[1]) else { return }
            moveSession(front.record.sessionId, toWindow: target, at: parts.count > 2 ? Int(parts[2]) : nil)
        case "merge-into":
            // merge-into <window id prefix> [index]: the front window's tabs join that window.
            guard parts.count >= 2, let (source, _) = resolveFrontWindow(),
                  let target = devWindow(prefix: parts[1]) else { return }
            mergeWindow(source, into: target, at: parts.count > 2 ? Int(parts[2]) : nil)
        case "probe":
            // probe <x> <y>: what a tab drop and a title-bar drop of the front
            // window would do at that screen point. y counts from the bottom.
            guard parts.count == 3, let x = Double(parts[1]), let y = Double(parts[2]),
                  let front = frontSession() else { return }
            let point = NSPoint(x: x, y: y)
            devLog("tab drop: \(TabDragController.shared.describeDrop(of: front.record.sessionId, at: point))")
            devLog("window drop: \(WindowDragTracker.shared.describeTarget(of: front.windowId, at: point))")
            return
        case "hierarchy":
            if let (_, window) = resolveFrontWindow(), let content = window.contentView {
                devLog("contentView frame=\(NSStringFromRect(content.frame)) bounds=\(NSStringFromRect(content.bounds))")
                devLogHierarchy(content, depth: 0, maxDepth: 6)
            }
        case "save":
            saveWindowConfigs()
        case "quit":
            NSApp.terminate(nil)
            return
        default:
            devLog("unknown command '\(verb)'")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.devLogStatus()
        }
    }

    private func devLogHierarchy(_ view: NSView, depth: Int, maxDepth: Int) {
        let indent = String(repeating: "  ", count: depth)
        let name = String(describing: type(of: view))
        devLog("\(indent)\(name) frame=\(NSStringFromRect(view.frame)) hidden=\(view.isHidden) alpha=\(view.alphaValue) subviews=\(view.subviews.count)")
        guard depth < maxDepth else { return }
        for sub in view.subviews.prefix(8) {
            devLogHierarchy(sub, depth: depth + 1, maxDepth: maxDepth)
        }
    }

    private func devWindow(prefix: String) -> UUID? {
        windows.keys.first { $0.uuidString.lowercased().hasPrefix(prefix.lowercased()) }
    }

    func devLogStatus() {
        for (windowId, window) in windows {
            let windowTabs = windowSessions[windowId]
            let responder = window.firstResponder
            let responderName = responder.map { String(describing: type(of: $0)) } ?? "nil"
            devLog("window \(windowId.uuidString.prefix(8)) title='\(window.title)' key=\(window.isKeyWindow) frame=\(NSStringFromRect(window.frame)) tabs=\(windowTabs?.sessionIds.count ?? 0) firstResponder=\(responderName)")
            if let bar = tabBarScreenRect(of: windowId) {
                devLog("  bar=\(NSStringFromRect(bar)) vertical=\(windowContent(of: windowId)?.isVertical ?? false) titleBar=\(NSStringFromRect(titleBarScreenRect(of: window))) chips=\(windowTabs?.sessionIds.compactMap { windowTabs?.chipFrames[$0].map(NSStringFromRect) } ?? [])")
            } else {
                devLog("  bar=hidden titleBar=\(NSStringFromRect(titleBarScreenRect(of: window)))")
            }
            for (index, sessionId) in (windowTabs?.sessionIds ?? []).enumerated() {
                guard let record = sessions[sessionId] else {
                    devLog("  [\(index)] \(sessionId) has no record")
                    continue
                }
                let hosted = record.surface.hostedView
                let focusInside = (responder as? NSView).map { $0 === hosted || $0.isDescendant(of: hosted) } ?? false
                devLog("  [\(index)] \(record.monitor.state.sessionName ?? "?") active=\(windowTabs?.activeSessionId == sessionId) inWindow=\(hosted.window === window) hidden=\(hosted.isHiddenOrHasHiddenAncestor) focus=\(focusInside)")
            }
        }
        devLog("sessions=\(sessions.count) surfaces=\(TerminalSurfaceRegistry.shared.allSurfaces().count) tabManagers=\(tabManagers.count) windows=\(windows.count)")
    }
}
