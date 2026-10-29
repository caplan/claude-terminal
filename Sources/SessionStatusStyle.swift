import AppKit
import SwiftUI

/// One place for the color and label of a session's status, shared by the
/// menu bar popover and the session tab bar so a session looks the same in
/// both.
enum SessionStatusStyle {
    static func color(_ status: SessionStatus) -> Color {
        switch status {
        case .idle: return .gray
        case .thinking: return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 0.95, green: 0.65, blue: 0.15, alpha: 1)
                : NSColor(red: 0.75, green: 0.45, blue: 0.05, alpha: 1)
        })
        case .toolUse: return .blue
        case .streaming: return .green
        case .disconnected: return Color(nsColor: .separatorColor)
        }
    }

    static func label(_ status: SessionStatus) -> String {
        switch status {
        case .idle: return "Idle"
        case .thinking: return "Thinking..."
        case .toolUse: return "Using tool"
        case .streaming: return "Streaming"
        case .disconnected: return "Disconnected"
        }
    }
}
