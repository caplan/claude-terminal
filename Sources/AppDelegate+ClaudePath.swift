import AppKit

extension AppDelegate {
    /// Discover the Claude CLI binary the host shell would use, falling
    /// back to common install locations and finally a "locate manually"
    /// dialog. Persists the resolved path so subsequent launches skip the
    /// shell probe. Also captures the user shell's environment so the
    /// terminal child shells inherit PATH/PROMPT/etc., not the trimmed
    /// AppKit launch env.
    func resolveClaudePath() {
        userShellEnvironment = resolveUserEnvironment()
        if let saved = UserDefaults.standard.string(forKey: "claudePath"),
           FileManager.default.isExecutableFile(atPath: saved) {
            claudePath = saved
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(home)/.nvm/current/bin/claude",
            "\(home)/.cargo/bin/claude",
        ]
        let fm = FileManager.default
        for path in candidates {
            if fm.isExecutableFile(atPath: path) {
                claudePath = path
                return
            }
        }
        if let shellPath = resolveViaShell() {
            claudePath = shellPath
            return
        }
        if let userPath = askUserForClaudePath() {
            claudePath = userPath
        }
    }

    /// Spawns the user's login shell with `-l -c env` so we capture the
    /// full PATH/etc. exactly the way iTerm/Terminal would. Used to
    /// populate child terminal shells with the right environment.
    private func resolveUserEnvironment() -> [String: String]? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-l", "-c", "env"]
        proc.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                            "SHELL": shell,
                            "TERM": "xterm-256color"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        var env: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq])
            let value = String(line[line.index(after: eq)...])
            env[key] = value
        }
        return env.isEmpty ? nil : env
    }

    private func resolveViaShell() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-l", "-c", "which claude"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : path
    }

    /// Last-resort fallback when the CLI isn't found: prompt the user to
    /// locate the binary manually, persist the chosen path, or quit. Recurs
    /// if the picker is cancelled — never returns nil unless the user
    /// chooses Quit (which terminates the process).
    func askUserForClaudePath() -> String? {
        let alert = NSAlert()
        alert.messageText = "Claude CLI not found"
        alert.informativeText = "claude-terminal couldn't find the Claude CLI.\n\nInstall it with: npm install -g @anthropic-ai/claude-code\n\nOr click \"Locate\" to find it manually."
        alert.addButton(withTitle: "Locate...")
        alert.addButton(withTitle: "Quit")
        alert.alertStyle = .warning

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            NSApp.terminate(nil)
            return nil
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select the claude executable"
        panel.prompt = "Select"
        panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
        guard panel.runModal() == .OK, let url = panel.url else {
            return askUserForClaudePath()
        }
        let path = url.path
        UserDefaults.standard.set(path, forKey: "claudePath")
        return path
    }
}
