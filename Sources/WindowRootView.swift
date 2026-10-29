import SwiftUI

/// The stack of session views: one ContentView per session, with only the
/// active one visible and hit-testable. Inactive sessions stay mounted so
/// their portal bindings, doc viewers and sidebar scroll state survive a
/// switch. The tab bar is not here; WindowContentView hosts it separately so
/// it is never a SwiftUI sibling of the Metal terminal views.
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
