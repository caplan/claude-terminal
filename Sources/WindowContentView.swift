import AppKit
import Combine
import SwiftUI

/// The window's content view, laid out in AppKit: the session tab bar along
/// the top in its own NSHostingView, and the stack of session views below in
/// another. Two hosting views on purpose: SwiftUI does not reliably
/// invalidate siblings of the Metal terminal view, so the bar must not share
/// a tree with it (the same reason SidebarView has SidebarHostView). Showing
/// or hiding the bar is a constraint change here, never a restructuring of
/// the tree that holds the terminals.
final class WindowContentView: NSView {
    let tabBarHost: NSHostingView<SessionTabBar>
    let sessionsHost: NSHostingView<WindowRootView>

    private let sessions: WindowSessions
    private let tabBarHeight: NSLayoutConstraint
    private var cancellables = Set<AnyCancellable>()

    init(sessions: WindowSessions, sidebarState: SidebarState, frame: NSRect) {
        self.sessions = sessions
        tabBarHost = NSHostingView(rootView: SessionTabBar(sessions: sessions))
        sessionsHost = NSHostingView(rootView: WindowRootView(sessions: sessions, sidebarState: sidebarState))
        tabBarHeight = tabBarHost.heightAnchor.constraint(equalToConstant: 0)
        super.init(frame: frame)

        tabBarHost.translatesAutoresizingMaskIntoConstraints = false
        sessionsHost.translatesAutoresizingMaskIntoConstraints = false
        sessionsHost.frame = frame
        addSubview(tabBarHost)
        addSubview(sessionsHost)
        NSLayoutConstraint.activate([
            tabBarHost.topAnchor.constraint(equalTo: topAnchor),
            tabBarHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabBarHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabBarHeight,
            sessionsHost.topAnchor.constraint(equalTo: tabBarHost.bottomAnchor),
            sessionsHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            sessionsHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            sessionsHost.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        updateTabBarVisibility()
        sessions.$sessionIds
            .combineLatest(sessions.$tabBarHidden)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.updateTabBarVisibility() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTabBarVisibility() }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var isTabBarVisible: Bool { !tabBarHost.isHidden }

    private func updateTabBarVisibility() {
        let show = sessions.showsTabBar(withOneTab: UserDefaults.standard.bool(forKey: "showTabBarWithOneTab"))
        guard show != isTabBarVisible || tabBarHeight.constant != (show ? SessionTabBar.height : 0) else { return }
        tabBarHeight.constant = show ? SessionTabBar.height : 0
        tabBarHost.isHidden = !show
        layoutSubtreeIfNeeded()
    }
}
