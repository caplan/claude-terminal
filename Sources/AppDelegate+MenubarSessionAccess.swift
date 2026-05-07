import AppKit

extension AppDelegate {
    func activeSessionSnapshots() -> [(windowId: UUID, monitor: SessionMonitor)] {
        sessionMonitors.map { ($0.key, $0.value) }
    }

    func focusWindow(windowId: UUID) {
        guard let window = windows[windowId] else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openPastSession(directory: String, sessionName: String?) {
        let name = sessionName ?? (directory as NSString).lastPathComponent
        let opts = "--name \"\(name)\" --continue"
        openWindowDirectly(workingDirectory: directory, claudeOptions: opts, sessionName: name)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Two-step destructive prompt for the menubar's past-session list:
    /// step 1 lets the user choose between hiding the entry or deleting
    /// the folder; step 2 (`confirmDeleteFolder`) is a critical-style
    /// confirmation before actually unlinking.
    func promptDeletePastSession(directory: String, sessionName: String) {
        menuBarController?.hidePopoverForModalPrompt()

        let displayDir = directory.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path)
            ? "~" + directory.dropFirst(FileManager.default.homeDirectoryForCurrentUser.path.count)
            : directory

        let alert = NSAlert()
        alert.messageText = "Remove \"\(sessionName)\" from the list?"
        alert.informativeText = "You can remove just this entry from the menu bar, or delete the entire project folder at \(displayDir) from disk."
        alert.addButton(withTitle: "Hide from Menu")
        alert.addButton(withTitle: "Delete Folder…")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            hidePastSession(directory: directory)
        case .alertSecondButtonReturn:
            confirmDeleteFolder(directory: directory, displayDir: displayDir)
        default:
            break
        }
    }

    private func hidePastSession(directory: String) {
        var hidden = Set(UserDefaults.standard.stringArray(forKey: "hiddenSessionDirs") ?? [])
        hidden.insert(directory)
        UserDefaults.standard.set(Array(hidden), forKey: "hiddenSessionDirs")
        NotificationCenter.default.post(name: .sessionListDidChange, object: nil)
    }

    private func confirmDeleteFolder(directory: String, displayDir: String) {
        let alert = NSAlert()
        alert.messageText = "Delete \(displayDir)?"
        alert.informativeText = "This will permanently delete the folder and all its contents from disk. This cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .critical
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try FileManager.default.removeItem(atPath: directory)
            hidePastSession(directory: directory)
        } catch {
            let err = NSAlert()
            err.messageText = "Could not delete folder"
            err.informativeText = error.localizedDescription
            err.alertStyle = .warning
            err.runModal()
        }
    }
}
