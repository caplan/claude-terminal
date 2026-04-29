import AppKit
import SwiftUI
import UserNotifications

struct WindowConfig: Codable {
    var workingDirectory: String
    var claudeOptions: String?
    var sessionName: String?
    var sidebarVisible: Bool
    var sidebarWidth: Double?
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?

    private var windows: [UUID: NSWindow] = [:]
    private var tabManagers: [UUID: TabManager] = [:]
    private var sidebarStates: [UUID: SidebarState] = [:]
    private var sessionMonitors: [UUID: SessionMonitor] = [:]
    private var documentTabStates: [UUID: DocumentTabState] = [:]
    private var windowConfigs: [UUID: WindowConfig] = [:]
    private var windowMenu: NSMenu?
    private var launchedViaURL = false
    var cliArguments: CLIArguments?
    var menuBarController: MenuBarController?

    var tabManager: TabManager? { tabManagers.values.first }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        // Suppress the auto-injected "Show Tab Bar" / "Merge All Windows"
        // items AppKit adds when native window tabbing is enabled — this
        // app uses its own per-window tab bar.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        resolveClaudePath()
        _ = GhosttyApp.shared
        NSApp.setActivationPolicy(.regular)
        AppearanceMode.current().apply()
        HookInstaller.installIfNeeded()
        let notificationsEnabled = UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
        PreferencesView.writeNotificationFlag(notificationsEnabled)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        setupMainMenu()
        menuBarController = MenuBarController()
        menuBarController?.setup()
        NotificationCenter.default.addObserver(self, selector: #selector(renameSession), name: .renameSession, object: nil)
        NSApp.activate(ignoringOtherApps: true)
        installCLISymlinkIfNeeded()
        suggestJiraCLIIfNeeded()
        if let cli = cliArguments {
            let dir = cli.workingDirectory ?? FileManager.default.currentDirectoryPath
            let name = cli.name ?? (dir as NSString).lastPathComponent
            var opts = cli.claudeOptions
            let extra = "--name \"\(name)\" --continue"
            opts = opts.map { $0 + " " + extra } ?? extra
            openWindowDirectly(workingDirectory: dir, claudeOptions: opts, sessionName: name)
        } else if !launchedViaURL, let saved = restoreSavedWindows(), !saved.isEmpty {
            for config in saved {
                var opts = config.claudeOptions ?? ""
                if !opts.contains("--continue") {
                    opts = opts.isEmpty ? "--continue" : "--continue \(opts)"
                }
                restoreWindow(config: config, claudeOptions: opts)
            }
        } else if !launchedViaURL {
            createNewWindow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // Routes Finder double-click / `open -a claude-terminal foo.md` / drag-to-dock
    // into a markdown tab in the frontmost window. If no session window exists,
    // spins up a new session rooted at the file's parent directory.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.isFileURL {
            handleOpenFile(url: url)
        }
    }

    private func handleOpenFile(url: URL) {
        let path = url.path
        let ext = (path as NSString).pathExtension.lowercased()
        let isMarkdown = ext == "md" || ext == "markdown" || ext == "mdown"

        guard isMarkdown else {
            NSWorkspace.shared.open(url)
            return
        }

        if let (windowId, window) = resolveFrontWindow(),
           let tabState = documentTabStates[windowId] {
            tabState.open(path: path)
            sessionMonitors[windowId]?.addDocument(path: path)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let parent = (path as NSString).deletingLastPathComponent
        openWindowDirectly(workingDirectory: parent, claudeOptions: nil, sessionName: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            guard let (windowId, _) = self.resolveFrontWindow(),
                  let tabState = self.documentTabStates[windowId] else { return }
            tabState.open(path: path)
            self.sessionMonitors[windowId]?.addDocument(path: path)
        }
    }

    private func resolveFrontWindow() -> (UUID, NSWindow)? {
        if let key = NSApp.keyWindow,
           let (id, w) = windows.first(where: { $0.value === key }) {
            return (id, w)
        }
        if let main = NSApp.mainWindow,
           let (id, w) = windows.first(where: { $0.value === main }) {
            return (id, w)
        }
        if let (id, w) = windows.first {
            return (id, w)
        }
        return nil
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !windows.isEmpty else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Save open windows?"
        alert.informativeText = "Reopen \(windows.count) session\(windows.count == 1 ? "" : "s") on next launch."
        alert.addButton(withTitle: "Save & Quit")
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            saveWindowConfigs()
            return .terminateNow
        case .alertSecondButtonReturn:
            UserDefaults.standard.removeObject(forKey: "savedWindows")
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString),
              url.scheme == "claude-terminal" else { return }

        launchedViaURL = true

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        let dir = queryItems.first(where: { $0.name == "dir" })?.value
        var claudeOptions = queryItems.first(where: { $0.name == "claude-options" })?.value

        if let dir {
            let name = (dir as NSString).lastPathComponent
            let nameOpt = "--name \"\(name)\""
            let continueOpt = "--continue"
            claudeOptions = [claudeOptions, nameOpt, continueOpt].compactMap { $0 }.joined(separator: " ")
            let opts = claudeOptions
            DispatchQueue.main.async { [self] in
                openWindowDirectly(workingDirectory: dir, claudeOptions: opts, sessionName: name)
                NSApp.activate(ignoringOtherApps: true)
            }
        } else {
            DispatchQueue.main.async { [self] in
                createNewWindow(workingDirectory: nil, claudeOptions: claudeOptions)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func openWindowDirectly(workingDirectory dir: String, claudeOptions opts: String?, sessionName: String?) {
        let windowId = UUID()
        let tabId = UUID()
        let sessionId = UUID()
        let sidebarVisible = UserDefaults.standard.object(forKey: "sidebarDefaultVisible") as? Bool ?? true
        let sidebarState = SidebarState(defaultVisible: sidebarVisible)
        let resolvedName = sessionName ?? (dir as NSString).lastPathComponent
        let monitor = SessionMonitor(sessionId: sessionId, initialName: resolvedName, workingDirectory: dir)
        let tabState = DocumentTabState()
        let contentView = ContentView(
            tabId: tabId,
            sessionId: sessionId,
            sidebarState: sidebarState,
            monitor: monitor,
            tabState: tabState,
            workingDirectory: dir,
            claudeOptions: opts
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = resolvedName
        window.minSize = NSSize(width: 600, height: 300)
        window.contentMinSize = NSSize(width: 600, height: 300)

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1080, height: 600)
        window.contentView = hostingView

        let autosaveKey = resolvedName
        window.setFrameAutosaveName("claude-terminal-\(autosaveKey)")
        if !window.setFrameUsingName(window.frameAutosaveName) {
            window.center()
        }
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.makeKeyAndOrderFront(nil)

        windows[windowId] = window
        tabManagers[tabId] = TabManager(window: window, tabId: tabId)
        sidebarStates[windowId] = sidebarState
        sessionMonitors[windowId] = monitor
        documentTabStates[windowId] = tabState
        windowConfigs[windowId] = WindowConfig(
            workingDirectory: dir,
            claudeOptions: opts,
            sessionName: resolvedName,
            sidebarVisible: sidebarState.isVisible
        )
        NotificationCenter.default.post(name: .sessionListDidChange, object: nil)
    }

    @objc func createNewWindow(workingDirectory: String? = nil, claudeOptions: String? = nil, initialName: String? = nil) {
        var opts = claudeOptions
        var resolvedName = initialName

        let panel = NSOpenPanel()
        panel.appearance = nil
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a working directory for Claude"
        panel.prompt = "Open"
        if let workingDirectory {
            panel.directoryURL = URL(fileURLWithPath: workingDirectory)
        } else {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        }

        let nameLabel = NSTextField(labelWithString: "Session name:")
        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        nameField.placeholderString = "optional"
        if let initialName, !initialName.isEmpty {
            nameField.stringValue = initialName
        }
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let nameRow = NSStackView(views: [nameLabel, nameField])
        nameRow.orientation = .horizontal
        nameRow.spacing = 8

        let newSessionCheck = NSButton(checkboxWithTitle: "New session", target: nil, action: nil)
        let dangerCheck = NSButton(checkboxWithTitle: "Live dangerously", target: nil, action: nil)
        let checkRow = NSStackView(views: [newSessionCheck, dangerCheck])
        checkRow.orientation = .horizontal
        checkRow.spacing = 16

        let stack = NSStackView(views: [nameRow, checkRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        panel.accessoryView = stack
        panel.isAccessoryViewDisclosed = true

        if let initialURL = panel.directoryURL {
            dangerCheck.state = Self.isDangerSavedForDir(initialURL.path) ? .on : .off
        }
        let pickerDelegate = OpenPanelSelectionDelegate(dangerCheck: dangerCheck)
        panel.delegate = pickerDelegate

        if let panelWindow = panel as NSWindow? {
            var frame = panelWindow.frame
            frame.size.height = max(frame.size.height, 500)
            panelWindow.setFrame(frame, display: false)
        }

        let modalResult = panel.runModal()
        withExtendedLifetime(pickerDelegate) {}
        guard modalResult == .OK, let url = panel.url else { return }
        let dir = url.path

        Self.setDangerSaved(dangerCheck.state == .on, forDir: dir)

        var extra: [String] = []
        var sessionName = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        if sessionName.isEmpty {
            sessionName = url.lastPathComponent
        }
        resolvedName = sessionName
        extra.append("--name \"\(sessionName)\"")
        if newSessionCheck.state == .off { extra.append("--continue") }
        if dangerCheck.state == .on { extra.append("--dangerously-skip-permissions") }
        if !extra.isEmpty {
            let joined = extra.joined(separator: " ")
            opts = opts.map { $0 + " " + joined } ?? joined
        }
        let windowId = UUID()
        let tabId = UUID()
        let sessionId = UUID()
        let sidebarVisible = UserDefaults.standard.object(forKey: "sidebarDefaultVisible") as? Bool ?? true
        let sidebarState = SidebarState(defaultVisible: sidebarVisible)
        let monitor = SessionMonitor(sessionId: sessionId, initialName: resolvedName, workingDirectory: dir)
        let tabState = DocumentTabState()

        let contentView = ContentView(
            tabId: tabId,
            sessionId: sessionId,
            sidebarState: sidebarState,
            monitor: monitor,
            tabState: tabState,
            workingDirectory: dir,
            claudeOptions: opts
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = monitor.state.sessionName ?? resolvedName ?? (dir as NSString).lastPathComponent
        window.minSize = NSSize(width: 600, height: 300)
        window.contentMinSize = NSSize(width: 600, height: 300)

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1080, height: 600)
        window.contentView = hostingView

        let autosaveKey = resolvedName ?? (dir as NSString).lastPathComponent
        window.setFrameAutosaveName("claude-terminal-\(autosaveKey)")
        if !window.setFrameUsingName(window.frameAutosaveName) {
            window.center()
        }
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.makeKeyAndOrderFront(nil)

        windows[windowId] = window
        tabManagers[tabId] = TabManager(window: window, tabId: tabId)
        sidebarStates[windowId] = sidebarState
        sessionMonitors[windowId] = monitor
        documentTabStates[windowId] = tabState
        windowConfigs[windowId] = WindowConfig(
            workingDirectory: dir,
            claudeOptions: opts,
            sessionName: monitor.state.sessionName,
            sidebarVisible: sidebarState.isVisible
        )
        NotificationCenter.default.post(name: .sessionListDidChange, object: nil)
        print("[claude-terminal] Window \(windowId) created (session: \(sessionId), dir: \(workingDirectory ?? "default"), options: \(claudeOptions ?? "none"))")
    }

    private(set) var claudePath: String = "claude"
    private(set) var userShellEnvironment: [String: String]?

    private func resolveClaudePath() {
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

    private func askUserForClaudePath() -> String? {
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

    // MARK: - CLI Symlink

    private func installCLISymlinkIfNeeded() {
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

    // MARK: - Window Save/Restore

    private func saveWindowConfigs() {
        var configs: [WindowConfig] = []
        for (windowId, _) in windows {
            guard var config = windowConfigs[windowId] else { continue }
            if let monitor = sessionMonitors[windowId] {
                config.sessionName = monitor.state.sessionName
            }
            if let sidebar = sidebarStates[windowId] {
                config.sidebarVisible = sidebar.isVisible
                config.sidebarWidth = Double(sidebar.width)
            }
            configs.append(config)
        }
        if let data = try? JSONEncoder().encode(configs) {
            UserDefaults.standard.set(data, forKey: "savedWindows")
        }
    }

    private func restoreSavedWindows() -> [WindowConfig]? {
        guard let data = UserDefaults.standard.data(forKey: "savedWindows") else { return nil }
        UserDefaults.standard.removeObject(forKey: "savedWindows")
        return try? JSONDecoder().decode([WindowConfig].self, from: data)
    }

    private func restoreWindow(config: WindowConfig, claudeOptions: String) {
        let windowId = UUID()
        let tabId = UUID()
        let sessionId = UUID()
        let dir = config.workingDirectory
        let sidebarState = SidebarState(defaultVisible: config.sidebarVisible, width: config.sidebarWidth.map { CGFloat($0) })
        let monitor = SessionMonitor(sessionId: sessionId, initialName: config.sessionName, workingDirectory: dir)
        let tabState = DocumentTabState()

        let contentView = ContentView(
            tabId: tabId,
            sessionId: sessionId,
            sidebarState: sidebarState,
            monitor: monitor,
            tabState: tabState,
            workingDirectory: dir,
            claudeOptions: claudeOptions
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = monitor.state.sessionName ?? (dir as NSString).lastPathComponent
        window.minSize = NSSize(width: 600, height: 300)
        window.contentMinSize = NSSize(width: 600, height: 300)

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1080, height: 600)
        window.contentView = hostingView

        let autosaveKey = config.sessionName ?? (dir as NSString).lastPathComponent
        window.setFrameAutosaveName("claude-terminal-\(autosaveKey)")
        if !window.setFrameUsingName(window.frameAutosaveName) {
            window.center()
        }
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.makeKeyAndOrderFront(nil)

        windows[windowId] = window
        tabManagers[tabId] = TabManager(window: window, tabId: tabId)
        sidebarStates[windowId] = sidebarState
        sessionMonitors[windowId] = monitor
        documentTabStates[windowId] = tabState
        windowConfigs[windowId] = config
        NotificationCenter.default.post(name: .sessionListDidChange, object: nil)
    }

    // MARK: - Jira CLI Suggestion

    private func suggestJiraCLIIfNeeded() {
        guard !JiraTicketDetector.isJiraCLIAvailable else { return }
        guard !UserDefaults.standard.bool(forKey: "jiraCLISuggestionSkipped") else { return }
        guard JiraTicketDetector.isJiraAvailable else { return }

        let alert = NSAlert()
        alert.messageText = "Install Jira CLI?"
        alert.informativeText = "The Jira CLI (go-jira) lets claude-terminal show ticket titles in the sidebar when your branch includes a Jira key.\n\nInstall with: brew install go-jira"
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Don't Ask Again")
        alert.alertStyle = .informational

        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            UserDefaults.standard.set(true, forKey: "jiraCLISuggestionSkipped")
        }
    }

    // MARK: - Menu Bar

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Claude Terminal", action: #selector(showAboutPanel), keyEquivalent: "")
        appMenu.addItem(.separator())
        let updateItem = appMenu.addItem(withTitle: "Check for Updates…", action: #selector(Updater.checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = Updater.shared
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings...", action: #selector(openPreferences), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Uninstall Claude Terminal...", action: #selector(uninstallApp), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Claude Terminal", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Session", action: #selector(newWindowFromMenu), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Open Session...", action: #selector(newWindowFromMenu), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(toggleSidebar), keyEquivalent: "b")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Rename Session...", action: #selector(renameSession), keyEquivalent: "R")
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        let windowMenuItem = NSMenuItem()
        windowMenu = NSMenu(title: "Window")
        windowMenu?.delegate = self
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func newWindowFromMenu() {
        createNewWindow()
    }

    @objc private func openPreferences() {
        PreferencesWindowController.shared.showWindow()
    }

    @objc private func showAboutPanel() {
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

    @objc private func uninstallApp() {
        let alert = NSAlert()
        alert.messageText = "Uninstall Claude Terminal?"
        alert.informativeText = "This will remove:\n\n• The app from /Applications\n• ~/.claude-terminal/ (session data & hooks)\n• ~/.local/bin/claude-terminal symlink\n• Claude Code hook/statusLine entries from ~/.claude/settings.json\n• App preferences\n\nThis cannot be undone."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path

        // Remove ~/.claude-terminal/
        try? fm.removeItem(atPath: "\(home)/.claude-terminal")

        // Remove CLI symlink (may need admin)
        // Remove CLI symlink
        let localBinSymlink = "\(home)/.local/bin/claude-terminal"
        try? fm.removeItem(atPath: localBinSymlink)
        // Clean up legacy /usr/local/bin symlink if present
        let legacySymlink = "/usr/local/bin/claude-terminal"
        if let dest = try? fm.destinationOfSymbolicLink(atPath: legacySymlink),
           dest.contains("claude-terminal.app") {
            try? fm.removeItem(atPath: legacySymlink)
        }

        // Remove hook/statusLine entries from ~/.claude/settings.json
        let claudeSettingsPath = "\(home)/.claude/settings.json"
        if let data = fm.contents(atPath: claudeSettingsPath),
           var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
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
            if let cleaned = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
                try? cleaned.write(to: URL(fileURLWithPath: claudeSettingsPath), options: .atomic)
            }
        }

        // Remove preferences
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "org.claire.claude-terminal")

        // Remove the app
        if let appPath = Bundle.main.bundlePath as String? {
            try? FileManager.default.removeItem(atPath: appPath)
        }

        // Quit
        NSApp.terminate(nil)
    }

    @objc private func toggleSidebar() {
        guard let keyWindow = NSApp.keyWindow else { return }
        guard let (windowId, _) = windows.first(where: { $0.value === keyWindow }) else { return }
        sidebarStates[windowId]?.toggle()
    }

    @objc private func renameSession(_ sender: Any? = nil) {
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

    // MARK: - Danger flag persistence

    private static let dangerDirsKey = "dangerDirs"

    static func isDangerSavedForDir(_ dir: String) -> Bool {
        let dirs = UserDefaults.standard.stringArray(forKey: dangerDirsKey) ?? []
        return dirs.contains(dir)
    }

    static func setDangerSaved(_ enabled: Bool, forDir dir: String) {
        var dirs = UserDefaults.standard.stringArray(forKey: dangerDirsKey) ?? []
        if enabled {
            if !dirs.contains(dir) { dirs.append(dir) }
        } else {
            dirs.removeAll { $0 == dir }
        }
        UserDefaults.standard.set(dirs, forKey: dangerDirsKey)
    }

    // MARK: - Menubar Session Access

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

    // MARK: - Stubs for GhosttyTerminalView

    func isCommandPaletteEffectivelyVisible(for window: NSWindow?) -> Bool { false }

    func tabManagerFor(window: NSWindow?) -> TabManager? {
        guard let window else { return nil }
        return tabManagers.values.first { $0.window === window }
    }
    func tabManagerFor(tabId: UUID) -> TabManager? { tabManagers[tabId] }

    func workspaceContainingPanel(withId panelId: UUID) -> Workspace? { nil }

    func workspaceContainingPanel(panelId: UUID, preferredWorkspaceId: UUID) -> WorkspaceContainingPanelResult? { nil }

    func workspaceFor(surface: TerminalSurface) -> Workspace? { nil }

    func workspaceFor(tabId: UUID) -> Workspace? { nil }

    func refreshTerminalSurfacesAfterGhosttyConfigReload(source: String = "") {
        for surface in TerminalSurfaceRegistry.shared.allSurfaces() {
            if let s = surface.surface {
                ghostty_surface_refresh(s)
            }
        }
    }

    func recordJumpUnreadFocusIfExpected(surfaceId: UUID) {}
    func recordJumpUnreadFocusIfExpected(tabId: UUID, surfaceId: UUID) {}

    func applicationWillTerminate(_ notification: Notification) {
        menuBarController?.teardown()
        menuBarController = nil
        windows.removeAll()
        tabManagers.removeAll()
        sidebarStates.removeAll()
        sessionMonitors.removeAll()
        windowConfigs.removeAll()
    }
}

extension AppDelegate: NSMenuDelegate {
    private static let windowListTag = 1000

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === windowMenu else { return }

        menu.items.filter { $0.tag == Self.windowListTag }.forEach { menu.removeItem($0) }

        let sorted = windows.sorted { $0.value.title.localizedCaseInsensitiveCompare($1.value.title) == .orderedAscending }
        for (index, (windowId, window)) in sorted.enumerated() {
            let title = window.title.isEmpty ? "Untitled" : window.title
            let item = NSMenuItem(title: title, action: #selector(activateWindow(_:)), keyEquivalent: index < 9 ? "\(index + 1)" : "")
            item.representedObject = windowId
            item.tag = Self.windowListTag
            item.state = (window === NSApp.keyWindow) ? .on : .off
            if let monitor = sessionMonitors[windowId] {
                item.image = FaviconLoader.favicon(for: monitor.state.workingDirectory)
            }
            menu.addItem(item)
        }
    }

    @objc private func activateWindow(_ sender: NSMenuItem) {
        guard let windowId = sender.representedObject as? UUID,
              let window = windows[windowId] else { return }
        window.makeKeyAndOrderFront(nil)
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else { return }
        if let windowId = windows.first(where: { $0.value === closingWindow })?.key {
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

final class OpenPanelSelectionDelegate: NSObject, NSOpenSavePanelDelegate {
    weak var dangerCheck: NSButton?

    init(dangerCheck: NSButton) {
        self.dangerCheck = dangerCheck
    }

    func panelSelectionDidChange(_ sender: Any?) {
        guard let panel = sender as? NSOpenPanel else { return }
        let url = panel.urls.first ?? panel.directoryURL
        guard let path = url?.path else { return }
        dangerCheck?.state = AppDelegate.isDangerSavedForDir(path) ? .on : .off
    }
}
