import AppKit
import SwiftUI
import UserNotifications

struct OpenDocState: Codable, Equatable {
    var path: String
    var scrollY: Double
}

struct WindowConfig: Codable {
    var workingDirectory: String
    var claudeOptions: String?
    var sessionName: String?
    var sidebarVisible: Bool
    var sidebarWidth: Double?
    var openDocs: [OpenDocState]?
    var activeDocPath: String?
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?

    var windows: [UUID: NSWindow] = [:]
    var tabManagers: [UUID: TabManager] = [:]
    var sidebarStates: [UUID: SidebarState] = [:]
    var sessionMonitors: [UUID: SessionMonitor] = [:]
    var documentTabStates: [UUID: DocumentTabState] = [:]
    var windowConfigs: [UUID: WindowConfig] = [:]
    var windowMenu: NSMenu?
    var launchedViaURL = false
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
        Self.pruneStaleFiles()
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
        guard ViewableDocument.isViewable(path) else {
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

    func resolveFrontWindow() -> (UUID, NSWindow)? {
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

    /// Shared window builder. Creates NSWindow + ContentView + all per-window
    /// state objects, registers everything in the parallel dictionaries, and
    /// returns the DocumentTabState so restore paths can reopen tabs.
    @discardableResult
    func installWindow(
        workingDirectory dir: String,
        claudeOptions opts: String?,
        sessionName: String?,
        sidebarVisible: Bool,
        sidebarWidth: CGFloat? = nil,
        storedConfig: WindowConfig? = nil
    ) -> (windowId: UUID, tabState: DocumentTabState) {
        let windowId = UUID()
        let tabId = UUID()
        let sessionId = UUID()
        let sidebarState = SidebarState(defaultVisible: sidebarVisible, width: sidebarWidth)
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
        window.title = monitor.state.sessionName ?? resolvedName
        window.minSize = NSSize(width: 600, height: 300)
        window.contentMinSize = NSSize(width: 600, height: 300)

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1080, height: 600)
        window.contentView = hostingView

        window.setFrameAutosaveName("claude-terminal-\(resolvedName)")
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
        windowConfigs[windowId] = storedConfig ?? WindowConfig(
            workingDirectory: dir,
            claudeOptions: opts,
            sessionName: resolvedName,
            sidebarVisible: sidebarState.isVisible
        )
        NotificationCenter.default.post(name: .sessionListDidChange, object: nil)
        print("[claude-terminal] Window \(windowId) (session \(sessionId), dir \(dir), opts: \(opts ?? "none"))")
        return (windowId, tabState)
    }

    func openWindowDirectly(workingDirectory dir: String, claudeOptions opts: String?, sessionName: String?) {
        let sidebarVisible = UserDefaults.standard.object(forKey: "sidebarDefaultVisible") as? Bool ?? true
        installWindow(
            workingDirectory: dir,
            claudeOptions: opts,
            sessionName: sessionName,
            sidebarVisible: sidebarVisible
        )
    }

    @objc func createNewWindow(workingDirectory: String? = nil, claudeOptions: String? = nil, initialName: String? = nil) {
        guard let result = runWorkingDirectoryPicker(initialDir: workingDirectory, initialName: initialName) else {
            return
        }
        let opts = mergeClaudeOptions(base: claudeOptions, extra: result.options)
        let sidebarVisible = UserDefaults.standard.object(forKey: "sidebarDefaultVisible") as? Bool ?? true
        installWindow(
            workingDirectory: result.dir,
            claudeOptions: opts,
            sessionName: result.sessionName,
            sidebarVisible: sidebarVisible
        )
    }

    /// Runs the directory-chooser modal with the session-name field and the
    /// new-session / danger checkboxes. Returns nil if the user cancels.
    /// On OK: persists the danger flag for the chosen dir and returns the
    /// path, the resolved session name (falls back to the dir's last path
    /// component), and the assembled `--name`/`--continue`/`--dangerously…`
    /// option fragment ready to splice into the Claude argv.
    private func runWorkingDirectoryPicker(
        initialDir: String?,
        initialName: String?
    ) -> (dir: String, sessionName: String, options: String)? {
        let panel = NSOpenPanel()
        panel.appearance = nil
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a working directory for Claude"
        panel.prompt = "Open"
        panel.directoryURL = initialDir.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser

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
        guard modalResult == .OK, let url = panel.url else { return nil }
        let dir = url.path

        Self.setDangerSaved(dangerCheck.state == .on, forDir: dir)

        var sessionName = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        if sessionName.isEmpty {
            sessionName = url.lastPathComponent
        }
        var extra: [String] = ["--name \"\(sessionName)\""]
        if newSessionCheck.state == .off { extra.append("--continue") }
        if dangerCheck.state == .on { extra.append("--dangerously-skip-permissions") }
        return (dir, sessionName, extra.joined(separator: " "))
    }

    private func mergeClaudeOptions(base: String?, extra: String) -> String {
        guard let base, !base.isEmpty else { return extra }
        return extra.isEmpty ? base : "\(base) \(extra)"
    }

    var claudePath: String = "claude"
    var userShellEnvironment: [String: String]?



    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        menuBarController?.teardown()
        menuBarController = nil
        windows.removeAll()
        tabManagers.removeAll()
        sidebarStates.removeAll()
        sessionMonitors.removeAll()
        windowConfigs.removeAll()
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
