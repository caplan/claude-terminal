import AppKit

extension AppDelegate {
    // MARK: - Public entry points

    /// Builds the right-click menu shown over the window chrome.
    func terminalBackgroundContextMenu(for windowId: UUID) -> NSMenu {
        let menu = NSMenu()
        let setItem = NSMenuItem(
            title: "Set Terminal Background Color…",
            action: #selector(handleChooseTerminalBackground(_:)),
            keyEquivalent: ""
        )
        setItem.target = self
        setItem.representedObject = windowId
        menu.addItem(setItem)

        if customTerminalBackgrounds[windowId] != nil {
            let removeItem = NSMenuItem(
                title: "Remove Custom Background",
                action: #selector(handleRemoveTerminalBackground(_:)),
                keyEquivalent: ""
            )
            removeItem.target = self
            removeItem.representedObject = windowId
            menu.addItem(removeItem)
        }
        return menu
    }

    // MARK: - Menu actions

    @objc func handleChooseTerminalBackground(_ sender: Any?) {
        guard let windowId = resolveWindowId(from: sender) else { return }
        colorPanelWindowId = windowId

        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelDidChange(_:)))
        if let existing = customTerminalBackgrounds[windowId] {
            panel.color = existing
        }
        panel.makeKeyAndOrderFront(nil)
    }

    @objc func handleRemoveTerminalBackground(_ sender: Any?) {
        guard let windowId = resolveWindowId(from: sender) else { return }
        customTerminalBackgrounds.removeValue(forKey: windowId)
        terminalBackgroundObservations.removeValue(forKey: windowId)?.invalidate()
        if colorPanelWindowId == windowId {
            colorPanelWindowId = nil
        }
        resetTerminalBackground(windowId: windowId)
    }

    @objc func colorPanelDidChange(_ sender: Any?) {
        guard let panel = sender as? NSColorPanel,
              let windowId = colorPanelWindowId else { return }
        let color = panel.color.usingColorSpace(.sRGB) ?? panel.color
        customTerminalBackgrounds[windowId] = color
        applyTerminalBackground(windowId: windowId)
    }

    /// Main-menu entry points (View menu). Routes to the front window.
    @objc func chooseTerminalBackgroundFromMenu() {
        guard let (windowId, _) = resolveFrontWindow() else { return }
        let wrapped = NSMenuItem()
        wrapped.representedObject = windowId
        handleChooseTerminalBackground(wrapped)
    }

    @objc func resetTerminalBackgroundFromMenu() {
        guard let (windowId, _) = resolveFrontWindow() else { return }
        let wrapped = NSMenuItem()
        wrapped.representedObject = windowId
        handleRemoveTerminalBackground(wrapped)
    }

    // MARK: - Persistence / reapply

    /// Called on `.ghosttyConfigDidReload`, which is the one code path that
    /// wipes the per-surface override. Reapply ours.
    @objc func reapplyAllTerminalBackgrounds() {
        for windowId in customTerminalBackgrounds.keys {
            applyTerminalBackground(windowId: windowId)
        }
    }

    // MARK: - Surface plumbing

    private func applyTerminalBackground(windowId: UUID) {
        guard let color = customTerminalBackgrounds[windowId],
              let window = windows[windowId],
              let surfaceView = findGhosttySurfaceView(in: window)
        else { return }

        // The host-layer paint alone isn't enough: Ghostty's renderer still
        // fills cells with its config background color, which covers the
        // layer. Push a config override via ghostty_surface_update_config so
        // the renderer uses our color for the terminal content.
        let savedBg = window.backgroundColor
        let savedOpaque = window.isOpaque

        // Suppress the KVO reapply while our own apply cascade runs. Without
        // this, the CONFIG_CHANGE handler repaints the layer with a color
        // that is semantically identical but not bit-identical to our CGColor
        // (alpha + color-space normalization), which the observer reads as
        // "diverged" and loops on ghostty_surface_update_config's internal
        // lock until the process hangs.
        terminalBackgroundApplyInProgress.insert(windowId)

        surfaceView.backgroundColor = color
        surfaceView.applySurfaceBackground()

        if let runtimeSurface = surfaceView.terminalSurface?.surface,
           let config = buildBackgroundConfigOverride(color: color)
        {
            ghostty_surface_update_config(runtimeSurface, config)
            ghostty_config_free(config)
        }

        // Ghostty's CONFIG_CHANGE handler fires on the next main-loop tick
        // and calls applyWindowBackgroundIfActive(), which tints the chrome.
        // We only want the terminal content to change — restore chrome
        // after that handler has run, then lift the suppression so a real
        // post-/clear divergence can still be re-applied.
        DispatchQueue.main.async {
            DispatchQueue.main.async { [weak self] in
                window.backgroundColor = savedBg
                window.isOpaque = savedOpaque
                self?.terminalBackgroundApplyInProgress.remove(windowId)
            }
        }

        installBackgroundObserver(windowId: windowId, in: window)
    }

    private func buildBackgroundConfigOverride(color: NSColor) -> ghostty_config_t? {
        let base: ghostty_config_t?
        if let appConfig = GhosttyApp.shared.config {
            base = ghostty_config_clone(appConfig)
        } else {
            base = ghostty_config_new()
        }
        guard let config = base else { return nil }

        let hex = color.hexString()
        let content = "background = \(hex)\n"
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ct-terminal-bg-\(UUID().uuidString).conf")
        do {
            try content.write(to: tmpURL, atomically: true, encoding: .utf8)
        } catch {
            ghostty_config_free(config)
            return nil
        }
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        tmpURL.path.withCString { path in
            ghostty_config_load_file(config, path)
        }
        ghostty_config_finalize(config)
        return config
    }

    /// The per-surface `backgroundColor` override gets clobbered whenever
    /// Ghostty processes an OSC 11/111 or terminal-reset escape — which is
    /// exactly what Claude Code's `/clear` emits. Observe the
    /// `backgroundView.layer.backgroundColor` (where the color actually
    /// lands) and re-apply our override when it drifts.
    private func installBackgroundObserver(windowId: UUID, in window: NSWindow) {
        guard let hosted = TerminalSurfaceRegistry.shared.allSurfaces()
            .first(where: { $0.hostedView.window === window })?.hostedView,
              let bgView = hosted.subviews.first,
              let layer = bgView.layer
        else { return }

        // Ensure we don't stack observers.
        if terminalBackgroundObservations[windowId] != nil { return }

        let observation = layer.observe(\.backgroundColor, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.reapplyTerminalBackgroundIfDiverged(windowId: windowId)
            }
        }
        terminalBackgroundObservations[windowId] = observation
    }

    private func reapplyTerminalBackgroundIfDiverged(windowId: UUID) {
        guard !terminalBackgroundApplyInProgress.contains(windowId) else { return }
        guard let color = customTerminalBackgrounds[windowId],
              let window = windows[windowId],
              let hosted = TerminalSurfaceRegistry.shared.allSurfaces()
                .first(where: { $0.hostedView.window === window })?.hostedView,
              let bgView = hosted.subviews.first,
              let current = bgView.layer?.backgroundColor
        else { return }
        if current == color.cgColor { return }
        applyTerminalBackground(windowId: windowId)
    }

    private func resetTerminalBackground(windowId: UUID) {
        guard let window = windows[windowId],
              let surfaceView = findGhosttySurfaceView(in: window)
        else { return }

        let savedBg = window.backgroundColor
        let savedOpaque = window.isOpaque

        surfaceView.backgroundColor = nil
        surfaceView.applySurfaceBackground()

        // Push the app's base config so Ghostty's renderer reverts to the
        // default theme background.
        if let runtimeSurface = surfaceView.terminalSurface?.surface,
           let appConfig = GhosttyApp.shared.config,
           let cloned = ghostty_config_clone(appConfig)
        {
            ghostty_surface_update_config(runtimeSurface, cloned)
            ghostty_config_free(cloned)
        }

        DispatchQueue.main.async {
            DispatchQueue.main.async {
                window.backgroundColor = savedBg
                window.isOpaque = savedOpaque
            }
        }
    }

    private func findGhosttySurfaceView(in window: NSWindow) -> GhosttyNSView? {
        if let surface = TerminalSurfaceRegistry.shared.allSurfaces()
            .first(where: { $0.hostedView.window === window })
        {
            if let found = firstDescendant(of: surface.hostedView, ofType: GhosttyNSView.self) {
                return found
            }
        }
        if let root = window.contentView,
           let found = firstDescendant(of: root, ofType: GhosttyNSView.self)
        {
            return found
        }
        return nil
    }

    private func firstDescendant<T: NSView>(of view: NSView, ofType type: T.Type) -> T? {
        for sub in view.subviews {
            if let match = sub as? T { return match }
            if let nested = firstDescendant(of: sub, ofType: type) { return nested }
        }
        return nil
    }

    private func resolveWindowId(from sender: Any?) -> UUID? {
        if let item = sender as? NSMenuItem, let id = item.representedObject as? UUID {
            return id
        }
        return resolveFrontWindow()?.0
    }
}
