import AppKit

extension AppDelegate {
    // MARK: - Public entry points

    /// Builds the right-click menu shown over the window chrome. Acts on the
    /// session in front of that window.
    func terminalBackgroundContextMenu(for windowId: UUID) -> NSMenu {
        let menu = NSMenu()
        guard let sessionId = activeSession(in: windowId)?.sessionId else { return menu }
        let setItem = NSMenuItem(
            title: "Set Terminal Background Color…",
            action: #selector(handleChooseTerminalBackground(_:)),
            keyEquivalent: ""
        )
        setItem.target = self
        setItem.representedObject = sessionId
        menu.addItem(setItem)

        if customTerminalBackgrounds[sessionId] != nil {
            let removeItem = NSMenuItem(
                title: "Remove Custom Background",
                action: #selector(handleRemoveTerminalBackground(_:)),
                keyEquivalent: ""
            )
            removeItem.target = self
            removeItem.representedObject = sessionId
            menu.addItem(removeItem)
        }
        return menu
    }

    // MARK: - Menu actions

    @objc func handleChooseTerminalBackground(_ sender: Any?) {
        guard let sessionId = resolveSessionId(from: sender) else { return }
        colorPanelSessionId = sessionId

        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelDidChange(_:)))
        if let existing = customTerminalBackgrounds[sessionId] {
            panel.color = existing
        }
        panel.makeKeyAndOrderFront(nil)
    }

    @objc func handleRemoveTerminalBackground(_ sender: Any?) {
        guard let sessionId = resolveSessionId(from: sender) else { return }
        if let dir = terminalBackgroundDir(for: sessionId) {
            Self.setSavedTerminalBackground(hex: nil, forDir: dir)
        }
        customTerminalBackgrounds.removeValue(forKey: sessionId)
        terminalBackgroundObservations.removeValue(forKey: sessionId)?.invalidate()
        resetTerminalBackgroundReapplyBreaker(sessionId: sessionId)
        if colorPanelSessionId == sessionId {
            colorPanelSessionId = nil
        }
        resetTerminalBackground(sessionId: sessionId)
        NotificationCenter.default.post(name: .sessionListDidChange, object: nil)
    }

    @objc func colorPanelDidChange(_ sender: Any?) {
        guard let panel = sender as? NSColorPanel,
              let sessionId = colorPanelSessionId else { return }
        let color = panel.color.usingColorSpace(.sRGB) ?? panel.color
        customTerminalBackgrounds[sessionId] = color
        if let dir = terminalBackgroundDir(for: sessionId) {
            Self.setSavedTerminalBackground(hex: color.hexString(), forDir: dir)
        }
        resetTerminalBackgroundReapplyBreaker(sessionId: sessionId)
        applyTerminalBackground(sessionId: sessionId)
    }

    /// Main-menu entry points (View menu). Routes to the front session.
    @objc func chooseTerminalBackgroundFromMenu() {
        guard let front = frontSession() else { return }
        let wrapped = NSMenuItem()
        wrapped.representedObject = front.record.sessionId
        handleChooseTerminalBackground(wrapped)
    }

    @objc func resetTerminalBackgroundFromMenu() {
        guard let front = frontSession() else { return }
        let wrapped = NSMenuItem()
        wrapped.representedObject = front.record.sessionId
        handleRemoveTerminalBackground(wrapped)
    }

    // MARK: - Durable per-directory persistence

    private static let terminalBgByDirKey = "terminalBackgroundsByDir"

    /// Saved custom terminal background (hex) for a working directory, or nil.
    /// Keyed by directory — the same key sessions are identified by elsewhere
    /// (danger flag, open docs) — so the color survives closing and reopening
    /// a session rather than only an explicit Save & Quit.
    static func savedTerminalBackgroundHex(forDir dir: String) -> String? {
        let map = UserDefaults.standard.dictionary(forKey: terminalBgByDirKey) as? [String: String] ?? [:]
        return map[dir]
    }

    /// Persists (hex non-nil) or clears (hex nil) the custom background for a dir.
    static func setSavedTerminalBackground(hex: String?, forDir dir: String) {
        var map = UserDefaults.standard.dictionary(forKey: terminalBgByDirKey) as? [String: String] ?? [:]
        if let hex { map[dir] = hex } else { map.removeValue(forKey: dir) }
        UserDefaults.standard.set(map, forKey: terminalBgByDirKey)
    }

    /// Working directory of a session, used to key the persisted color.
    func terminalBackgroundDir(for sessionId: UUID) -> String? {
        sessions[sessionId]?.config.workingDirectory
    }

    // MARK: - Persistence / reapply

    /// Called on `.ghosttyConfigDidReload`, which is the one code path that
    /// wipes the per-surface override. Reapply ours.
    @objc func reapplyAllTerminalBackgrounds() {
        for sessionId in customTerminalBackgrounds.keys {
            applyTerminalBackground(sessionId: sessionId)
        }
    }

    /// On launch the Metal surface isn't mounted synchronously — `installWindow`
    /// returns before `GhosttyNSView` shows up in the view tree. Poll briefly
    /// and apply the restored color once the surface exists.
    func scheduleRestoredBackgroundApply(sessionId: UUID, attemptsRemaining: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self = self,
                  self.customTerminalBackgrounds[sessionId] != nil,
                  self.sessions[sessionId] != nil
            else { return }
            if self.findGhosttySurfaceView(forSession: sessionId) != nil {
                self.applyTerminalBackground(sessionId: sessionId)
            } else if attemptsRemaining > 0 {
                self.scheduleRestoredBackgroundApply(sessionId: sessionId, attemptsRemaining: attemptsRemaining - 1)
            }
        }
    }

    // MARK: - Surface plumbing

    private func applyTerminalBackground(sessionId: UUID) {
        guard let color = customTerminalBackgrounds[sessionId],
              let window = window(forSession: sessionId),
              let surfaceView = findGhosttySurfaceView(forSession: sessionId)
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
        terminalBackgroundApplyInProgress.insert(sessionId)
        NotificationCenter.default.post(name: .sessionListDidChange, object: nil)

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
                self?.terminalBackgroundApplyInProgress.remove(sessionId)
            }
        }

        installBackgroundObserver(sessionId: sessionId)
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
    private func installBackgroundObserver(sessionId: UUID) {
        guard let hosted = sessions[sessionId]?.surface.hostedView,
              let bgView = hosted.subviews.first,
              let layer = bgView.layer
        else { return }

        // Ensure we don't stack observers.
        if terminalBackgroundObservations[sessionId] != nil { return }

        let observation = layer.observe(\.backgroundColor, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.reapplyTerminalBackgroundIfDiverged(sessionId: sessionId)
            }
        }
        terminalBackgroundObservations[sessionId] = observation
    }

    // Circuit-breaker tuning. No legitimate event (e.g. `/clear` emitting
    // OSC 11) reapplies more than once or twice; a non-converging KVO loop
    // hits this within milliseconds.
    private static let terminalBgReapplyWindow: TimeInterval = 2.0
    private static let terminalBgReapplyMax = 12

    private func reapplyTerminalBackgroundIfDiverged(sessionId: UUID) {
        guard !terminalBackgroundApplyInProgress.contains(sessionId) else { return }
        // Breaker already tripped for this session: auto-reapply is disabled
        // until the user explicitly sets/removes a color.
        guard !terminalBackgroundReapplyTripped.contains(sessionId) else { return }
        guard let color = customTerminalBackgrounds[sessionId],
              let hosted = sessions[sessionId]?.surface.hostedView,
              let bgView = hosted.subviews.first,
              let current = bgView.layer?.backgroundColor
        else { return }
        if cgColorsVisuallyEqual(current, color.cgColor) { return }

        // Record this reapply and trip the breaker if they're arriving far
        // faster than any real terminal event could cause — the divergence
        // comparison must be failing to converge. Sever the KVO observation
        // so the cycle's source stops firing; the user's chosen color is
        // kept, only the self-healing reapply is disabled.
        let now = Date()
        var stamps = terminalBackgroundReapplyTimestamps[sessionId, default: []]
        stamps.append(now)
        stamps.removeAll { now.timeIntervalSince($0) > Self.terminalBgReapplyWindow }
        terminalBackgroundReapplyTimestamps[sessionId] = stamps
        if stamps.count > Self.terminalBgReapplyMax {
            terminalBackgroundReapplyTripped.insert(sessionId)
            terminalBackgroundReapplyTimestamps[sessionId] = nil
            terminalBackgroundObservations.removeValue(forKey: sessionId)?.invalidate()
            NSLog("[TerminalBackground] reapply circuit breaker tripped for session \(sessionId) — \(stamps.count) reapplies in \(Self.terminalBgReapplyWindow)s; disabling auto-reapply to prevent runaway CPU/disk writes")
            return
        }

        applyTerminalBackground(sessionId: sessionId)
    }

    /// Re-arm the breaker for a session — called when the user explicitly
    /// sets or removes a custom background, which is an unambiguous signal
    /// that this is intentional and the loop guard should reset.
    private func resetTerminalBackgroundReapplyBreaker(sessionId: UUID) {
        terminalBackgroundReapplyTripped.remove(sessionId)
        terminalBackgroundReapplyTimestamps[sessionId] = nil
    }

    /// CGColor's `==` is `CGColorEqualToColor`, which requires bit-identical
    /// components *and* colorspace. Ghostty's CONFIG_CHANGE handler repaints
    /// the layer with a color that's been round-tripped through a different
    /// colorspace (and sometimes alpha-normalized), so a reapplied color never
    /// compares equal to the original and the KVO observer loops. Normalize
    /// to sRGB and compare components with an 8-bit epsilon.
    private func cgColorsVisuallyEqual(_ a: CGColor, _ b: CGColor) -> Bool {
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let ac = a.converted(to: sRGB, intent: .defaultIntent, options: nil),
              let bc = b.converted(to: sRGB, intent: .defaultIntent, options: nil),
              let acs = ac.components, let bcs = bc.components,
              acs.count == bcs.count
        else { return false }
        let epsilon: CGFloat = 1.0 / 512.0
        for (x, y) in zip(acs, bcs) where abs(x - y) > epsilon { return false }
        return true
    }

    private func resetTerminalBackground(sessionId: UUID) {
        guard let window = window(forSession: sessionId),
              let surfaceView = findGhosttySurfaceView(forSession: sessionId)
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

    /// The Metal view of one session's surface. Looked up through the
    /// session's own hosted view, never "the surface in this window", because
    /// a window with tabs holds several.
    private func findGhosttySurfaceView(forSession sessionId: UUID) -> GhosttyNSView? {
        guard let hosted = sessions[sessionId]?.surface.hostedView else { return nil }
        return firstDescendant(of: hosted, ofType: GhosttyNSView.self)
    }

    private func firstDescendant<T: NSView>(of view: NSView, ofType type: T.Type) -> T? {
        for sub in view.subviews {
            if let match = sub as? T { return match }
            if let nested = firstDescendant(of: sub, ofType: type) { return nested }
        }
        return nil
    }

    private func resolveSessionId(from sender: Any?) -> UUID? {
        if let item = sender as? NSMenuItem, let id = item.representedObject as? UUID {
            return id
        }
        return frontSession()?.record.sessionId
    }
}
