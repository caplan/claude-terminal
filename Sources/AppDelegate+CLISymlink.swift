import AppKit

extension AppDelegate {
    /// Offers, on first launch, to drop a `~/.local/bin/claude-terminal`
    /// symlink so users can launch the GUI from a terminal. Once the user
    /// has answered ("Install" or "Skip") we never prompt again — an
    /// installed symlink is silently refreshed to the current executable
    /// path on each launch, so moving between /Applications and dev builds
    /// doesn't re-trigger the prompt.
    func installCLISymlinkIfNeeded() {
        guard let executablePath = Bundle.main.executablePath else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let binDir = "\(home)/.local/bin"
        let symlinkPath = "\(binDir)/claude-terminal"
        let fm = FileManager.default

        // Remove old /usr/local/bin symlink if it points to us
        let legacyPath = "/usr/local/bin/claude-terminal"
        if let dest = try? fm.destinationOfSymbolicLink(atPath: legacyPath),
           dest.contains("claude-terminal.app") {
            try? fm.removeItem(atPath: legacyPath)
        }

        let defaults = UserDefaults.standard
        let existingDestination = try? fm.destinationOfSymbolicLink(atPath: symlinkPath)

        // If the user previously installed (tracked via UserDefaults OR an
        // existing symlink pointing at some claude-terminal bundle), just
        // refresh it silently to the current executable path.
        let previouslyInstalled = defaults.string(forKey: "cliSymlinkInstalledFor") != nil
            || (existingDestination?.contains("claude-terminal.app") ?? false)

        if previouslyInstalled {
            if existingDestination != executablePath {
                refreshCLISymlink(at: symlinkPath, binDir: binDir, target: executablePath)
            }
            defaults.set(executablePath, forKey: "cliSymlinkInstalledFor")
            return
        }

        if defaults.bool(forKey: "cliSymlinkSkipped") {
            return
        }

        let alert = NSAlert()
        alert.messageText = "Install CLI launcher?"
        alert.informativeText = "Create ~/.local/bin/claude-terminal so you can run it from the terminal."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Skip")
        alert.alertStyle = .informational

        guard alert.runModal() == .alertFirstButtonReturn else {
            defaults.set(true, forKey: "cliSymlinkSkipped")
            return
        }

        if refreshCLISymlink(at: symlinkPath, binDir: binDir, target: executablePath) {
            defaults.set(executablePath, forKey: "cliSymlinkInstalledFor")
            defaults.set(false, forKey: "cliSymlinkSkipped")
        }
    }

    @discardableResult
    private func refreshCLISymlink(at symlinkPath: String, binDir: String, target: String) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: binDir, withIntermediateDirectories: true)
            // Detect the existing entry without following the link —
            // fileExists follows symlinks and reports false when the target
            // is missing, leaving a broken link in place that would make
            // createSymbolicLink fail with EEXIST.
            let isSymlink = (try? fm.destinationOfSymbolicLink(atPath: symlinkPath)) != nil
            if isSymlink || fm.fileExists(atPath: symlinkPath) {
                try fm.removeItem(atPath: symlinkPath)
            }
            try fm.createSymbolicLink(atPath: symlinkPath, withDestinationPath: target)
            return true
        } catch {
            print("[claude-terminal] Failed to install CLI symlink: \(error)")
            return false
        }
    }
}
