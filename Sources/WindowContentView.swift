import AppKit
import Combine
import SwiftUI

/// The window's content view, laid out in AppKit: the session tab bar in its
/// own NSHostingView, and the stack of session views in another. The bar runs
/// along the top, or down the left side as a rail (`TabBarPosition`). Two
/// hosting views on purpose: SwiftUI does not reliably invalidate siblings of
/// the Metal terminal view, so the bar must not share a tree with it (the same
/// reason SidebarView has SidebarHostView). Showing, hiding or moving the bar
/// is a constraint change here, never a restructuring of the tree that holds
/// the terminals.
final class WindowContentView: NSView {
    let tabBarHost: NSHostingView<SessionTabBar>
    let sessionsHost: NSHostingView<WindowRootView>

    private let sessions: WindowSessions
    private let railHandle = RailResizeHandle()
    private var cancellables = Set<AnyCancellable>()

    private let barHeight: NSLayoutConstraint
    private let railWidth: NSLayoutConstraint
    private var position: TabBarPosition?

    init(sessions: WindowSessions, sidebarState: SidebarState, frame: NSRect) {
        self.sessions = sessions
        tabBarHost = NSHostingView(rootView: SessionTabBar(sessions: sessions))
        sessionsHost = NSHostingView(rootView: WindowRootView(sessions: sessions, sidebarState: sidebarState))
        barHeight = tabBarHost.heightAnchor.constraint(equalToConstant: 0)
        railWidth = tabBarHost.widthAnchor.constraint(equalToConstant: 0)

        tabBarHost.translatesAutoresizingMaskIntoConstraints = false
        // AppKit alone sizes the bar. With SwiftUI's default sizing options,
        // the rail's content height became a maximum height constraint and
        // pulled the whole window down to it.
        tabBarHost.sizingOptions = []
        sessionsHost.translatesAutoresizingMaskIntoConstraints = false
        railHandle.translatesAutoresizingMaskIntoConstraints = false
        sessionsHost.frame = frame

        super.init(frame: frame)

        addSubview(tabBarHost)
        addSubview(sessionsHost)
        addSubview(railHandle)

        // Shared by both layouts: the sessions fill the bottom-right corner,
        // and the handle sits on the rail's trailing edge.
        NSLayoutConstraint.activate([
            tabBarHost.topAnchor.constraint(equalTo: topAnchor),
            tabBarHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            sessionsHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            sessionsHost.bottomAnchor.constraint(equalTo: bottomAnchor),
            railHandle.topAnchor.constraint(equalTo: topAnchor),
            railHandle.bottomAnchor.constraint(equalTo: bottomAnchor),
            railHandle.centerXAnchor.constraint(equalTo: tabBarHost.trailingAnchor),
            railHandle.widthAnchor.constraint(equalToConstant: 6),
        ])

        railHandle.onDrag = { [weak self] width in
            guard let self else { return }
            let range = WindowSessions.railWidthRange
            self.sessions.railWidth = min(max(width, range.lowerBound), range.upperBound)
        }
        railHandle.currentWidth = { [weak self] in self?.sessions.railWidth ?? 0 }

        updateLayout()
        sessions.$sessionIds
            .combineLatest(sessions.$tabBarHidden, sessions.$tabBarPinned)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.updateLayout() }
            .store(in: &cancellables)
        sessions.$railWidth
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateLayout() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateLayout() }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var isTabBarVisible: Bool { !tabBarHost.isHidden }

    /// The rail or the top bar, whichever the setting picks.
    var isVertical: Bool { position == .left }

    private lazy var topLayout: [NSLayoutConstraint] = [
        tabBarHost.trailingAnchor.constraint(equalTo: trailingAnchor),
        barHeight,
        sessionsHost.topAnchor.constraint(equalTo: tabBarHost.bottomAnchor),
        sessionsHost.leadingAnchor.constraint(equalTo: leadingAnchor),
    ]

    private lazy var leftLayout: [NSLayoutConstraint] = [
        tabBarHost.bottomAnchor.constraint(equalTo: bottomAnchor),
        railWidth,
        sessionsHost.topAnchor.constraint(equalTo: topAnchor),
        sessionsHost.leadingAnchor.constraint(equalTo: tabBarHost.trailingAnchor),
    ]

    private func updateLayout() {
        let newPosition = TabBarPosition.current
        let show = sessions.showsTabBar(withOneTab: UserDefaults.standard.bool(forKey: "showTabBarWithOneTab"))
        let height = show ? SessionTabBar.height : 0
        let width = show ? sessions.railWidth : 0
        let structural = newPosition != position || show == tabBarHost.isHidden

        // UserDefaults changes arrive for every key the app writes. Do
        // nothing unless the bar changed: a forced layout while SwiftUI is
        // mid-update aborts in AttributeGraph.
        guard structural || barHeight.constant != height || railWidth.constant != width else { return }

        if newPosition != position {
            NSLayoutConstraint.deactivate(newPosition == .left ? topLayout : leftLayout)
            NSLayoutConstraint.activate(newPosition == .left ? leftLayout : topLayout)
            position = newPosition
            if sessions.barIsVertical != (newPosition == .left) {
                sessions.barIsVertical = newPosition == .left
            }
        }
        // Only one of the two size constraints is active, per the layout.
        barHeight.constant = height
        railWidth.constant = width
        tabBarHost.isHidden = !show
        railHandle.isHidden = !(show && newPosition == .left)
        // Never a forced layoutSubtreeIfNeeded here: these updates can land
        // while SwiftUI is updating a hosting view, and a synchronous layout
        // then aborts in AttributeGraph. The next layout pass applies them.
        needsLayout = true
    }

    // MARK: - Hit areas for clicks and drags

    /// The bar's rect in window coordinates, or nil when it is hidden.
    var tabBarRectInWindow: NSRect? {
        guard isTabBarVisible else { return nil }
        return tabBarHost.convert(tabBarHost.bounds, to: nil)
    }

    /// True when a window-coordinate point falls on the bar or the rail.
    func tabBarContains(windowPoint: NSPoint) -> Bool {
        tabBarRectInWindow?.contains(windowPoint) ?? false
    }

    /// The drop index for a window-coordinate point over the bar, or nil
    /// when the point is not on the bar.
    func insertionIndex(atWindowPoint point: NSPoint) -> Int? {
        guard tabBarContains(windowPoint: point) else { return nil }
        // NSHostingView is flipped, so its local coordinates match SwiftUI's
        // top-left origin and the chip frames the bar recorded.
        let local = tabBarHost.convert(point, from: nil)
        return sessions.insertionIndex(at: local, vertical: isVertical)
    }
}

/// The thin strip on the rail's trailing edge that resizes it.
private final class RailResizeHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var currentWidth: (() -> CGFloat)?
    private var startX: CGFloat = 0
    private var startWidth: CGFloat = 0

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        startX = event.locationInWindow.x
        startWidth = currentWidth?() ?? 0
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(startWidth + event.locationInWindow.x - startX)
    }
}
