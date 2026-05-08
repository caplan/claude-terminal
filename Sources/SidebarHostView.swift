import SwiftUI

struct SidebarHostView: NSViewRepresentable {
    @ObservedObject var monitor: SessionMonitor
    @ObservedObject var tabState: DocumentTabState
    var width: CGFloat

    func makeNSView(context: Context) -> NSView {
        let hosting = NSHostingView(rootView: SidebarView(monitor: monitor, tabState: tabState, width: width))
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(hosting)
        let widthConstraint = hosting.widthAnchor.constraint(equalToConstant: width)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            widthConstraint,
        ])
        widthConstraint.identifier = "sidebarWidth"
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let hosting = nsView.subviews.first as? NSHostingView<SidebarView> else { return }
        hosting.rootView = SidebarView(monitor: monitor, tabState: tabState, width: width)
        if let wc = nsView.constraints.first(where: { $0.identifier == "sidebarWidth" }) ??
           hosting.constraints.first(where: { $0.identifier == "sidebarWidth" }) {
            wc.constant = width
        }
    }
}

struct SidebarDragHandle: View {
    @ObservedObject var sidebarState: SidebarState

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .padding(.horizontal, 2)
            .background(Color(nsColor: .windowBackgroundColor))
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let newWidth = sidebarState.width - value.translation.width
                        sidebarState.width = min(max(newWidth, 220), 500)
                    }
                    .onEnded { _ in
                        sidebarState.saveWidth()
                    }
            )
    }
}
