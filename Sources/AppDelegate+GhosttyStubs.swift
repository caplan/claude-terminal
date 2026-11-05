import AppKit

/// Host-side surface that GhosttyTerminalView (the vendored Ghostty Swift
/// code) expects on the AppDelegate. Most of this app doesn't use the
/// Ghostty workspace/panel/window-tab infrastructure, so the stubs return
/// `nil` / `false`. The two non-trivial entries route through TabManager
/// (we still use that) and trigger a visible-surface refresh after a
/// Ghostty config reload.
extension AppDelegate {
    func isCommandPaletteEffectivelyVisible(for window: NSWindow?) -> Bool { false }

    /// The manager of the session in front of `window`. A window with tabs
    /// holds several; the vendored code wants the one that has focus.
    func tabManagerFor(window: NSWindow?) -> TabManager? {
        guard let window else { return nil }
        if let windowId = windows.first(where: { $0.value === window })?.key,
           let tabId = activeSession(in: windowId)?.tabId,
           let manager = tabManagers[tabId] {
            return manager
        }
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
}
