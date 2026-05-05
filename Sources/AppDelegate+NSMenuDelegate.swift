import AppKit

extension AppDelegate: NSMenuDelegate {
    private static let windowListTag = 1000

    /// Re-populate the Window submenu with one row per open window. Tagged
    /// so we can wipe the prior list without disturbing static items. The
    /// first nine windows get Cmd-1..9 keyboard shortcuts.
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
