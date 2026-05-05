import AppKit

extension AppDelegate {
    /// Offers, on first launch (or when the bundle moves), to drop a
    /// `~/.local/bin/claude-terminal` symlink so users can launch the GUI
    /// from a terminal. Tracks state via UserDefaults so we don't nag — if
    /// the user picks "Skip" we record the executable path and stay quiet
    /// until the bundle moves to a new location.
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

        if let destination = try? fm.destinationOfSymbolicLink(atPath: symlinkPath),
           destination == executablePath {
            UserDefaults.standard.set(executablePath, forKey: "cliSymlinkInstalledFor")
            return
        }

        let previousPath = UserDefaults.standard.string(forKey: "cliSymlinkInstalledFor")
        if UserDefaults.standard.bool(forKey: "cliSymlinkSkipped"),
           previousPath == executablePath {
            return
        }

        let alert = NSAlert()
        alert.messageText = "Install CLI launcher?"
        alert.informativeText = "Create ~/.local/bin/claude-terminal so you can run it from the terminal."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Skip")
        alert.alertStyle = .informational

        guard alert.runModal() == .alertFirstButtonReturn else {
            UserDefaults.standard.set(true, forKey: "cliSymlinkSkipped")
            UserDefaults.standard.set(executablePath, forKey: "cliSymlinkInstalledFor")
            return
        }

        do {
            try fm.createDirectory(atPath: binDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: symlinkPath) {
                try fm.removeItem(atPath: symlinkPath)
            }
            try fm.createSymbolicLink(atPath: symlinkPath, withDestinationPath: executablePath)
            UserDefaults.standard.set(executablePath, forKey: "cliSymlinkInstalledFor")
            UserDefaults.standard.set(false, forKey: "cliSymlinkSkipped")
        } catch {
            print("[claude-terminal] Failed to install CLI symlink: \(error)")
        }
    }
}
