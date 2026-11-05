import AppKit
import SwiftUI

// Drag and drop between windows. Two drags share these helpers:
//
// - A tab chip drag (`TabDragController`). Drop it on its own bar to reorder,
//   on another window to move it there, or on the desktop to give it a window
//   of its own.
// - A window drag by the title bar (`WindowDragTracker`). Drop the window on
//   another window's title bar or tab bar, and all its tabs join that window.
//
// Both work in screen coordinates (`NSEvent.mouseLocation`), so they need no
// pasteboard and keep working when the pointer leaves the source window.

// MARK: - Screen geometry

extension AppDelegate {
    func windowContent(of windowId: UUID) -> WindowContentView? {
        windows[windowId]?.contentView as? WindowContentView
    }

    /// The front-most terminal window under a screen point, skipping
    /// `excluding`. Windows in front of it hide the ones behind, so only the
    /// first window whose frame holds the point counts.
    func terminalWindow(at screenPoint: NSPoint, excluding: UUID?) -> (id: UUID, window: NSWindow)? {
        for window in NSApp.orderedWindows {
            guard let terminal = window as? ClaudeTerminalWindow,
                  let id = terminal.windowId,
                  windows[id] === terminal,
                  terminal.isVisible, !terminal.isMiniaturized,
                  terminal.frame.contains(screenPoint) else { continue }
            if id == excluding { continue }
            return (id, terminal)
        }
        return nil
    }

    /// The title bar strip of a window, in screen coordinates.
    func titleBarScreenRect(of window: NSWindow) -> NSRect {
        let content = window.convertToScreen(window.contentLayoutRect)
        return NSRect(x: window.frame.minX, y: content.maxY,
                      width: window.frame.width, height: window.frame.maxY - content.maxY)
    }

    /// The tab bar or rail of a window, in screen coordinates, or nil when
    /// it is hidden.
    func tabBarScreenRect(of windowId: UUID) -> NSRect? {
        guard let window = windows[windowId],
              let rect = windowContent(of: windowId)?.tabBarRectInWindow else { return nil }
        return window.convertToScreen(rect)
    }

    /// The bar index a tab dropped at a screen point goes to, or nil when
    /// the point is not on the window's bar.
    func dropIndex(in windowId: UUID, at screenPoint: NSPoint) -> Int? {
        guard let window = windows[windowId] else { return nil }
        return windowContent(of: windowId)?.insertionIndex(atWindowPoint: window.convertPoint(fromScreen: screenPoint))
    }

    /// Shows or clears the insertion marker. Only one window shows it.
    func setDropIndex(_ index: Int?, in windowId: UUID?) {
        for (id, tabs) in windowSessions {
            let value = id == windowId ? index : nil
            if tabs.dropIndex != value { tabs.dropIndex = value }
        }
    }
}

// MARK: - Tab chip drag

final class TabDragController {
    static let shared = TabDragController()

    private enum Drop: Equatable {
        case none
        case reorder(window: UUID, index: Int)
        case move(window: UUID, index: Int?)
        case newWindow(at: NSPoint)
    }

    private var sessionId: UUID?
    private var preview: NSPanel?
    private let highlight = DropHighlight()

    /// Called on every drag change. The first call starts the drag.
    func update(sessionId id: UUID) {
        if sessionId != id { begin(id) }
        let point = NSEvent.mouseLocation
        movePreview(to: point)
        show(drop(at: point))
    }

    /// Called when the mouse goes up.
    func end() {
        guard let id = sessionId, let app = AppDelegate.shared else { return }
        let point = NSEvent.mouseLocation
        let target = drop(at: point)
        cleanUp()
        switch target {
        case .none:
            break
        case let .reorder(_, index):
            app.reorderSession(id, to: index)
        case let .move(window, index):
            app.moveSession(id, toWindow: window, at: index)
        case let .newWindow(at):
            app.moveSessionToNewWindow(id, at: at)
        }
    }

    /// Dev instances: what a drop of `id` at `point` would do, without
    /// doing it.
    func describeDrop(of id: UUID, at point: NSPoint) -> String {
        let saved = sessionId
        sessionId = id
        defer { sessionId = saved }
        return String(describing: drop(at: point))
    }

    private func begin(_ id: UUID) {
        cleanUp()
        sessionId = id
        guard let record = AppDelegate.shared?.sessions[id] else { return }
        let name = record.monitor.state.sessionName
            ?? (record.config.workingDirectory as NSString).lastPathComponent
        preview = Self.makePreview(name: name, directory: record.monitor.state.workingDirectory)
        preview?.orderFront(nil)
    }

    private func drop(at point: NSPoint) -> Drop {
        guard let app = AppDelegate.shared,
              let id = sessionId,
              let sourceId = app.windowId(forSession: id) else { return .none }
        let tabCount = app.windowSessions[sourceId]?.sessionIds.count ?? 0
        guard let (windowId, _) = app.terminalWindow(at: point, excluding: nil) else {
            // Over the desktop: a window of its own, unless it already has one.
            return tabCount > 1 ? .newWindow(at: point) : .none
        }
        if windowId == sourceId {
            guard let index = app.dropIndex(in: windowId, at: point) else { return .none }
            return .reorder(window: windowId, index: index)
        }
        // Anywhere over another window adds the tab there: at the marker when
        // over its bar, at the end otherwise.
        return .move(window: windowId, index: app.dropIndex(in: windowId, at: point))
    }

    private func show(_ drop: Drop) {
        guard let app = AppDelegate.shared else { return }
        switch drop {
        case .none, .newWindow:
            app.setDropIndex(nil, in: nil)
            highlight.hide()
        case let .reorder(window, index):
            app.setDropIndex(index, in: window)
            highlight.hide()
        case let .move(window, index):
            app.setDropIndex(index, in: window)
            if let frame = app.windows[window]?.frame {
                highlight.show(over: index != nil ? (app.tabBarScreenRect(of: window) ?? frame) : frame)
            }
        }
        preview?.alphaValue = drop == .none ? 0.5 : 0.95
    }

    private func movePreview(to point: NSPoint) {
        guard let preview else { return }
        preview.setFrameOrigin(NSPoint(x: point.x - 20, y: point.y - preview.frame.height / 2))
    }

    private func cleanUp() {
        AppDelegate.shared?.setDropIndex(nil, in: nil)
        highlight.hide()
        preview?.orderOut(nil)
        preview = nil
        sessionId = nil
    }

    private static func makePreview(name: String, directory: String?) -> NSPanel {
        let host = NSHostingView(rootView: TabDragPreview(name: name, directory: directory))
        let size = host.fittingSize
        let panel = FloatingPanel(size: NSSize(width: min(max(size.width, 80), 260), height: size.height))
        host.frame = NSRect(origin: .zero, size: panel.frame.size)
        panel.contentView = host
        panel.hasShadow = true
        panel.level = .popUpMenu
        return panel
    }
}

/// The chip-shaped label that follows the pointer during a tab drag.
private struct TabDragPreview: View {
    let name: String
    let directory: String?

    var body: some View {
        HStack(spacing: 6) {
            if let favicon = FaviconLoader.favicon(for: directory, size: 14) {
                Image(nsImage: favicon)
                    .resizable()
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: 10, weight: .medium))
            }
            Text(name)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .fixedSize()
    }
}

// MARK: - Window drag by the title bar

/// Follows a title-bar drag that `windowWillMove` reports. AppKit gives no
/// event when such a drag ends, so a timer reads the pointer and the mouse
/// button until the button goes up.
final class WindowDragTracker {
    static let shared = WindowDragTracker()

    private var sourceId: UUID?
    private var timer: Timer?
    private let highlight = DropHighlight()

    func begin(window: NSWindow) {
        guard sourceId == nil,
              NSEvent.pressedMouseButtons & 1 != 0,
              let terminal = window as? ClaudeTerminalWindow,
              let id = terminal.windowId else { return }
        sourceId = id
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
        // Common modes, so it also fires in AppKit's event-tracking loop.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let point = NSEvent.mouseLocation
        let target = self.target(at: point)
        if NSEvent.pressedMouseButtons & 1 == 0 {
            finish(target)
            return
        }
        guard let app = AppDelegate.shared else { return }
        if let target, let window = app.windows[target.windowId] {
            app.setDropIndex(target.index, in: target.windowId)
            var zone = app.titleBarScreenRect(of: window)
            if let bar = app.tabBarScreenRect(of: target.windowId) { zone = zone.union(bar) }
            highlight.show(over: zone)
        } else {
            app.setDropIndex(nil, in: nil)
            highlight.hide()
        }
    }

    /// The window to merge into: the front-most other window under the
    /// pointer, when the pointer is on its title bar or tab bar.
    private func target(at point: NSPoint) -> (windowId: UUID, index: Int?)? {
        guard let app = AppDelegate.shared,
              let sourceId,
              let (windowId, window) = app.terminalWindow(at: point, excluding: sourceId) else { return nil }
        let onTitleBar = app.titleBarScreenRect(of: window).contains(point)
        let onTabBar = app.tabBarScreenRect(of: windowId)?.contains(point) ?? false
        guard onTitleBar || onTabBar else { return nil }
        return (windowId, onTabBar ? app.dropIndex(in: windowId, at: point) : nil)
    }

    /// Dev instances: where a title-bar drop of `source` at `point` would
    /// merge, without merging.
    func describeTarget(of source: UUID, at point: NSPoint) -> String {
        let saved = sourceId
        sourceId = source
        defer { sourceId = saved }
        return target(at: point).map { "merge into \($0.windowId.uuidString.prefix(8)) at \($0.index.map(String.init) ?? "end")" } ?? "none"
    }

    private func finish(_ target: (windowId: UUID, index: Int?)?) {
        timer?.invalidate()
        timer = nil
        highlight.hide()
        AppDelegate.shared?.setDropIndex(nil, in: nil)
        let source = sourceId
        sourceId = nil
        if let source, let target {
            AppDelegate.shared?.mergeWindow(source, into: target.windowId, at: target.index)
        }
    }
}

// MARK: - Shared drag chrome

/// A borderless panel that floats above every window and lets the mouse
/// through, for the drag preview and the drop highlight.
private final class FloatingPanel: NSPanel {
    init(size: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        hasShadow = false
        level = .floating
        isReleasedWhenClosed = false
        collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The accent outline over the place a drop would go.
private final class DropHighlight {
    private var panel: FloatingPanel?

    func show(over rect: NSRect) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if panel.frame != rect { panel.setFrame(rect, display: true) }
        if !panel.isVisible { panel.orderFront(nil) }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel(size: NSSize(width: 10, height: 10))
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        view.layer?.borderWidth = 2
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        return panel
    }
}
