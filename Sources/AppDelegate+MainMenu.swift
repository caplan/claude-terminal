import AppKit

extension AppDelegate {
    // MARK: - Setup

    func setupMainMenu() {
        let mainMenu = NSMenu()
        mainMenu.addItem(submenuItem(makeAppSubmenu()))
        mainMenu.addItem(submenuItem(makeFileSubmenu()))
        mainMenu.addItem(submenuItem(makeEditSubmenu()))
        mainMenu.addItem(submenuItem(makeViewSubmenu()))
        mainMenu.addItem(submenuItem(makeWindowSubmenu()))
        NSApp.mainMenu = mainMenu
    }

    private func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private func makeAppSubmenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "About Claude Terminal", action: #selector(showAboutPanel), keyEquivalent: "")
        menu.addItem(.separator())
        let updateItem = menu.addItem(withTitle: "Check for Updates…", action: #selector(Updater.checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = Updater.shared
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings...", action: #selector(openPreferences), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Reveal Diagnostics in Finder", action: #selector(revealDiagnostics), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Uninstall Claude Terminal...", action: #selector(uninstallApp), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Claude Terminal", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private func makeFileSubmenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(withTitle: "New Session", action: #selector(newWindowFromMenu), keyEquivalent: "n")
        menu.addItem(withTitle: "Open Session...", action: #selector(newWindowFromMenu), keyEquivalent: "o")
        menu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        return menu
    }

    private func makeEditSubmenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Find…", action: #selector(findInDoc), keyEquivalent: "f")
        let findNext = menu.addItem(withTitle: "Find Next", action: #selector(findNextInDoc), keyEquivalent: "g")
        findNext.keyEquivalentModifierMask = [.command]
        let findPrev = menu.addItem(withTitle: "Find Previous", action: #selector(findPreviousInDoc), keyEquivalent: "g")
        findPrev.keyEquivalentModifierMask = [.command, .shift]
        return menu
    }

    private func makeViewSubmenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(withTitle: "Toggle Sidebar", action: #selector(toggleSidebar), keyEquivalent: "b")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Actual Size", action: #selector(docZoomReset), keyEquivalent: "0")
        menu.addItem(withTitle: "Zoom In", action: #selector(docZoomIn), keyEquivalent: "+")
        menu.addItem(withTitle: "Zoom Out", action: #selector(docZoomOut), keyEquivalent: "-")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Rename Session...", action: #selector(renameSession), keyEquivalent: "R")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Terminal Background Color…", action: #selector(chooseTerminalBackgroundFromMenu), keyEquivalent: "")
        menu.addItem(withTitle: "Reset Terminal Background", action: #selector(resetTerminalBackgroundFromMenu), keyEquivalent: "")
        return menu
    }

    private func makeWindowSubmenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.delegate = self
        windowMenu = menu
        return menu
    }

    // MARK: - @objc actions

    @objc func newWindowFromMenu() {
        createNewWindow()
    }

    @objc func openPreferences() {
        PreferencesWindowController.shared.showWindow()
    }

    @objc func docZoomIn() {
        frontTabState()?.zoomIn()
    }

    @objc func docZoomOut() {
        frontTabState()?.zoomOut()
    }

    @objc func docZoomReset() {
        frontTabState()?.zoomReset()
    }

    @objc func findInDoc() {
        guard let (windowId, window) = resolveFrontWindow() else { return }
        // If a markdown doc is visible, route Cmd+F to the doc find bar.
        // Otherwise drive the Ghostty terminal's native search (start_search
        // creates the SearchState, which mounts SurfaceSearchOverlay and
        // pipes keystrokes back into the Ghostty runtime via search:<needle>).
        if let tabState = documentTabStates[windowId], tabState.active != nil {
            window.makeFirstResponder(window.contentView)
            tabState.triggerFind()
            return
        }
        let frontSurface = TerminalSurfaceRegistry.shared.allSurfaces()
            .first { $0.hostedView.window === window }
        _ = frontSurface?.performBindingAction("start_search")
    }

    @objc func findNextInDoc() {
        frontTabState()?.findNext(backwards: false)
    }

    @objc func findPreviousInDoc() {
        frontTabState()?.findNext(backwards: true)
    }

    func frontTabState() -> DocumentTabState? {
        guard let (windowId, _) = resolveFrontWindow() else { return nil }
        return documentTabStates[windowId]
    }

    @objc func showAboutPanel() {
        let repoURL = "https://github.com/caplan/claude-terminal"
        let credits = NSMutableAttributedString(
            string: repoURL,
            attributes: [
                .link: URL(string: repoURL) as Any,
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.linkColor,
            ]
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
        ])
    }

    @objc func uninstallApp() {
        let alert = NSAlert()
        alert.messageText = "Uninstall Claude Terminal?"
        alert.informativeText = "This will remove:\n\n• The app from /Applications\n• ~/.claude-terminal/ (session data & hooks)\n• ~/.local/bin/claude-terminal symlink\n• Claude Code hook/statusLine entries from ~/.claude/settings.json\n• App preferences\n\nThis cannot be undone."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var failures: [String] = []

        if !scrubClaudeSettingsJSON() {
            failures.append("~/.claude/settings.json could not be cleaned — open it manually and remove any command containing 'claude-terminal'.")
        }
        if !removeClaudeTerminalSymlinks(home: home, fm: fm) {
            failures.append("~/.local/bin/claude-terminal could not be removed.")
        }
        // Session data cleanup happens last so the standalone uninstall
        // script (written at ~/.claude-terminal/uninstall.sh) stays around
        // as a fallback if something upstream failed.
        do {
            if fm.fileExists(atPath: "\(home)/.claude-terminal") {
                try fm.removeItem(atPath: "\(home)/.claude-terminal")
            }
        } catch {
            failures.append("~/.claude-terminal/ could not be removed: \(error.localizedDescription)")
        }
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "org.claire.claude-terminal")

        let appPath = Bundle.main.bundlePath
        var appDeleted = false
        do {
            try fm.removeItem(atPath: appPath)
            appDeleted = true
        } catch {
            failures.append("\(appPath) could not be removed — drag it to Trash manually. (\(error.localizedDescription))")
        }

        if failures.isEmpty {
            NSApp.terminate(nil)
            return
        }

        let result = NSAlert()
        result.messageText = appDeleted ? "Uninstall mostly complete" : "Uninstall incomplete"
        result.informativeText = failures.joined(separator: "\n\n")
        result.alertStyle = .warning
        result.addButton(withTitle: appDeleted ? "Quit" : "OK")
        if !appDeleted {
            result.addButton(withTitle: "Quit anyway")
        }
        let response = result.runModal()
        if appDeleted || response == .alertSecondButtonReturn {
            NSApp.terminate(nil)
        }
    }

    /// Removes the CLI symlink. Returns false only if a path that exists
    /// couldn't be removed — a missing symlink is success.
    @discardableResult
    private func removeClaudeTerminalSymlinks(home: String, fm: FileManager) -> Bool {
        var ok = true
        let primary = "\(home)/.local/bin/claude-terminal"
        if (try? fm.destinationOfSymbolicLink(atPath: primary)) != nil || fm.fileExists(atPath: primary) {
            do {
                try fm.removeItem(atPath: primary)
            } catch {
                ok = false
            }
        }
        // Clean up legacy /usr/local/bin symlink if it points at our app.
        let legacy = "/usr/local/bin/claude-terminal"
        if let dest = try? fm.destinationOfSymbolicLink(atPath: legacy),
           dest.contains("claude-terminal.app") {
            try? fm.removeItem(atPath: legacy)
        }
        return ok
    }

    /// Removes any hooks entry whose command mentions "claude-terminal" and
    /// drops the top-level statusLine if it points at our binary. Returns
    /// true if the file was cleaned (or already clean); false if it was
    /// unparseable and still contains claude-terminal references.
    @discardableResult
    private func scrubClaudeSettingsJSON() -> Bool {
        let fm = FileManager.default
        // If the file doesn't exist, there's nothing to scrub — succeed.
        if !fm.fileExists(atPath: ClaudeSettings.path.path) { return true }

        // If the file is present but unparseable, flag failure — we'd
        // rather tell the user than silently leave stale hooks behind.
        guard let data = fm.contents(atPath: ClaudeSettings.path.path),
              (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) != nil else {
            return false
        }

        ClaudeSettings.mutate { settings in
            if var hooks = settings["hooks"] as? [String: Any] {
                for (event, value) in hooks {
                    guard var entries = value as? [[String: Any]] else { continue }
                    entries.removeAll { entry in
                        if let hookList = entry["hooks"] as? [[String: Any]] {
                            return hookList.contains { ($0["command"] as? String)?.contains("claude-terminal") == true }
                        }
                        return (entry["command"] as? String)?.contains("claude-terminal") == true
                    }
                    hooks[event] = entries.isEmpty ? nil : entries
                }
                settings["hooks"] = hooks.isEmpty ? nil : hooks
            }
            if let sl = settings["statusLine"] as? [String: Any],
               (sl["command"] as? String)?.contains("claude-terminal") == true {
                settings.removeValue(forKey: "statusLine")
            }
        }
        return true
    }

    @objc func toggleSidebar() {
        guard let keyWindow = NSApp.keyWindow else { return }
        guard let (windowId, _) = windows.first(where: { $0.value === keyWindow }) else { return }
        sidebarStates[windowId]?.toggle()
    }

    @objc func renameSession(_ sender: Any? = nil) {
        guard let keyWindow = NSApp.keyWindow else { return }
        guard let (windowId, _) = windows.first(where: { $0.value === keyWindow }),
              let monitor = sessionMonitors[windowId] else { return }

        let alert = NSAlert()
        alert.messageText = "Rename Session"
        alert.informativeText = "Enter a new name for this session:"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = monitor.state.sessionName ?? ""
        field.placeholderString = "Session name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        monitor.renameSession(name.isEmpty ? nil : name)
        keyWindow.title = name.isEmpty ? "Session" : name
    }

    func windowForSession(_ sessionId: UUID) -> NSWindow? {
        for (windowId, monitor) in sessionMonitors {
            if monitor.sessionId == sessionId { return windows[windowId] }
        }
        return nil
    }
}
