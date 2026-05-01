import AppKit
import SwiftUI

final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private let viewModel = SessionListViewModel()
    private var clickOutsideMonitor: Any?
    private var globalHoverMonitor: Any?
    private var localHoverMonitor: Any?
    private var hoverDismissTimer: Timer?

    var isShown: Bool { panel?.isVisible ?? false }

    func setup() {
        let visible = UserDefaults.standard.object(forKey: "menuBarIconVisible") as? Bool ?? true
        if visible {
            createStatusItem()
        }
    }

    func teardown() {
        hoverDismissTimer?.invalidate()
        hoverDismissTimer = nil
        removeClickOutsideMonitor()
        removeHoverMonitors()
        panel?.close()
        panel = nil
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        viewModel.stopListening()
    }

    func updateVisibility() {
        let visible = UserDefaults.standard.object(forKey: "menuBarIconVisible") as? Bool ?? true
        if visible {
            if statusItem == nil { createStatusItem() }
        } else {
            dismissPanel()
            removeHoverMonitors()
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
            }
        }
    }

    func updateTriggerMode() {
        let mode = UserDefaults.standard.string(forKey: "menuBarTrigger") ?? "hover"
        if mode == "hover" {
            installHoverMonitors()
        } else {
            removeHoverMonitors()
        }
    }

    // MARK: - Private

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            if let img = NSImage(systemSymbolName: "apple.terminal.fill", accessibilityDescription: "Claude Terminal") {
                button.image = img
            } else {
                button.title = "CT"
            }
            button.target = self
            button.action = #selector(statusItemClicked(_:))
        }

        statusItem = item

        let mode = UserDefaults.standard.string(forKey: "menuBarTrigger") ?? "hover"
        if mode == "hover" {
            installHoverMonitors()
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if isShown {
            dismissPanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard !isShown else { return }
        guard let button = statusItem?.button,
              let buttonWindow = button.window else { return }

        viewModel.refresh()

        let contentView = MenuBarPopoverView(viewModel: viewModel) { [weak self] in
            self?.dismissPanel()
        }
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.setFrameSize(hostingView.fittingSize)

        let contentSize = hostingView.fittingSize

        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.isMovable = false
        p.contentView = hostingView

        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(buttonRect)
        let x = screenRect.midX - contentSize.width / 2
        let y = screenRect.minY - contentSize.height - 4
        p.setFrameOrigin(NSPoint(x: x, y: y))

        p.orderFrontRegardless()
        panel = p

        installClickOutsideMonitor()
    }

    func hidePopoverForModalPrompt() {
        dismissPanel()
    }

    private func dismissPanel() {
        hoverDismissTimer?.invalidate()
        hoverDismissTimer = nil
        TooltipWindow.shared.hide()
        panel?.close()
        panel = nil
        removeClickOutsideMonitor()
        viewModel.stopListening()
    }

    // MARK: - Click-outside dismiss

    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.isShown, let panelWindow = self.panel else { return }
            if !panelWindow.frame.contains(NSEvent.mouseLocation) {
                self.dismissPanel()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }

    // MARK: - Hover

    private func installHoverMonitors() {
        removeHoverMonitors()
        globalHoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.checkHover()
        }
        localHoverMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.checkHover()
            return event
        }
    }

    private func removeHoverMonitors() {
        if let m = globalHoverMonitor { NSEvent.removeMonitor(m); globalHoverMonitor = nil }
        if let m = localHoverMonitor { NSEvent.removeMonitor(m); localHoverMonitor = nil }
        hoverDismissTimer?.invalidate()
        hoverDismissTimer = nil
    }

    private func isMouseOverButton() -> Bool {
        guard let button = statusItem?.button, let buttonWindow = button.window else { return false }
        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(buttonRect)
        return screenRect.contains(NSEvent.mouseLocation)
    }

    private func isMouseOverPanel() -> Bool {
        panel?.frame.contains(NSEvent.mouseLocation) ?? false
    }

    private func checkHover() {
        let overButton = isMouseOverButton()
        let overPanel = isMouseOverPanel()

        if overButton && !isShown {
            hoverDismissTimer?.invalidate()
            hoverDismissTimer = nil
            showPanel()
        } else if isShown && (overButton || overPanel) {
            hoverDismissTimer?.invalidate()
            hoverDismissTimer = nil
        } else if isShown && !overButton && !overPanel {
            if hoverDismissTimer == nil {
                hoverDismissTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                    guard let self else { return }
                    if !self.isMouseOverButton() && !self.isMouseOverPanel() {
                        self.dismissPanel()
                    }
                    self.hoverDismissTimer = nil
                }
            }
        }
    }
}
