import AppKit

/// NSWindow subclass that owns a windowId and shows the terminal-background
/// context menu on right-click. Right-clicks on the terminal content are
/// consumed by the Ghostty view; the ones that bubble up to the window are
/// those on the window chrome (title bar and empty frame), which is exactly
/// where we want this menu to appear.
final class ClaudeTerminalWindow: NSWindow {
    var windowId: UUID?

    /// Intercept right-click before the terminal view consumes it so our
    /// context menu fires over the terminal content area. Clicks in the
    /// title bar / chrome fall through to the system.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .rightMouseDown,
           let contentView,
           let windowId,
           isLocationInTerminalContent(event.locationInWindow, contentView: contentView),
           let menu = AppDelegate.shared?.terminalBackgroundContextMenu(for: windowId)
        {
            NSMenu.popUpContextMenu(menu, with: event, for: contentView)
            return
        }
        super.sendEvent(event)
    }

    private func isLocationInTerminalContent(_ locationInWindow: NSPoint, contentView: NSView) -> Bool {
        let localPoint = contentView.convert(locationInWindow, from: nil)
        return contentView.bounds.contains(localPoint)
    }
}
