import AppKit
import SwiftUI

final class TooltipWindow {
    static let shared = TooltipWindow()
    private var panel: NSPanel?

    func show(name: String, directory: String, anchor: NSPoint) {
        let content = TooltipView(name: name, directory: directory)
        let hostingView = NSHostingView(rootView: content)
        hostingView.setFrameSize(hostingView.fittingSize)
        let size = hostingView.fittingSize

        let existing = panel ?? {
            let p = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
                backing: .buffered,
                defer: false
            )
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.level = .popUpMenu
            p.isMovable = false
            p.ignoresMouseEvents = true
            return p
        }()

        existing.contentView = hostingView
        existing.setContentSize(size)

        var origin = NSPoint(x: anchor.x - size.width / 2, y: anchor.y + 8)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main {
            let vf = screen.visibleFrame
            origin.x = min(max(origin.x, vf.minX + 4), vf.maxX - size.width - 4)
            if origin.y + size.height > vf.maxY - 4 {
                origin.y = anchor.y - size.height - 8
            }
            origin.y = max(origin.y, vf.minY + 4)
        }
        existing.setFrameOrigin(origin)
        existing.orderFrontRegardless()
        panel = existing
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

private struct TooltipView: View {
    let name: String
    let directory: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
            Text(directory)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Color(nsColor: .secondaryLabelColor))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .fixedSize()
    }
}
