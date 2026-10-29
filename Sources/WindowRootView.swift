import SwiftUI

/// The window's root: one ContentView per session, stacked, with only the
/// active one visible and hit-testable. Inactive sessions stay mounted so
/// their portal bindings, doc viewers and sidebar scroll state survive a
/// switch. The tab bar and rail are added here in a later step.
struct WindowRootView: View {
    @ObservedObject var sessions: WindowSessions
    @ObservedObject var sidebarState: SidebarState

    var body: some View {
        ZStack {
            ForEach(sessions.sessionIds, id: \.self) { sessionId in
                if let record = AppDelegate.shared?.sessions[sessionId] {
                    let isActive = sessionId == sessions.activeSessionId
                    ContentView(record: record, sidebarState: sidebarState, isActiveSession: isActive)
                        .opacity(isActive ? 1 : 0)
                        .allowsHitTesting(isActive)
                        .zIndex(isActive ? 1 : 0)
                }
            }
        }
    }
}
