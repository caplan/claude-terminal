import AppKit
import SwiftUI

func sidebarAbbreviatePath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path.hasPrefix(home) {
        return "~" + path.dropFirst(home.count)
    }
    return path
}

func sidebarAbbreviateFilePath(_ path: String) -> String {
    let filename = (path as NSString).lastPathComponent
    let dir = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
    return dir.isEmpty ? filename : "\(dir)/\(filename)"
}

func sidebarDocumentIcon(_ path: String) -> String {
    if ViewableDocument.isImage(path) { return "photo" }
    return "doc.text"
}

func sidebarPermissionBadge(_ mode: String?) -> (label: String, color: Color)? {
    switch mode {
    case "bypassPermissions": return ("YOLO", .red)
    case "plan": return ("PLAN", .blue)
    default: return nil
    }
}

func sidebarStatusColor(_ status: SessionStatus) -> Color {
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

func sidebarStatusLabel(_ status: SessionStatus) -> String {
    switch status {
    case .idle: return "Idle"
    case .thinking: return "Working"
    case .toolUse: return "Using tool"
    case .streaming: return "Streaming"
    case .disconnected: return "Disconnected"
    }
}

func sidebarContextBarColor(_ fraction: Double) -> Color {
    if fraction > 0.9 { return .red }
    if fraction > 0.7 { return .orange }
    return .blue
}

func sidebarFormatTokens(_ count: Int) -> String {
    if count >= 1_000_000 {
        return String(format: "%.1fM", Double(count) / 1_000_000.0)
    } else if count >= 1_000 {
        return String(format: "%.1fK", Double(count) / 1_000.0)
    }
    return "\(count)"
}

func sidebarFormatCost(_ usd: Double) -> String {
    // Clamp tiny negatives (floating-point noise after a reset) to zero.
    let v = max(0, usd)
    if v < 0.01 {
        return String(format: "$%.4f", v)
    }
    return String(format: "$%.2f", v)
}

func sidebarFormatDuration(_ ms: Int) -> String {
    let seconds = max(0, ms) / 1000
    if seconds < 60 { return "\(seconds)s" }
    let minutes = seconds / 60
    let secs = seconds % 60
    if minutes < 60 { return "\(minutes)m \(secs)s" }
    let hours = minutes / 60
    let mins = minutes % 60
    return "\(hours)h \(mins)m"
}

func sidebarFormatLatency(_ ms: Int) -> String {
    if ms < 1000 { return "\(ms)ms" }
    return String(format: "%.1fs", Double(ms) / 1000.0)
}

func sidebarLatencyColor(_ ms: Int) -> Color {
    if ms > 10000 { return .red }
    if ms > 5000 { return .orange }
    return .green
}

func sidebarToolVerb(_ tool: String) -> String {
    switch tool {
    case "Bash": return "Running command"
    case "Read": return "Reading file"
    case "Write": return "Writing file"
    case "Edit": return "Editing file"
    case "Grep": return "Searching content"
    case "Glob": return "Finding files"
    case "Agent": return "Spawning agent"
    case "WebFetch": return "Fetching URL"
    case "WebSearch": return "Searching web"
    case "TaskCreate": return "Creating task"
    case "TaskUpdate": return "Updating task"
    case "LSP": return "Code intelligence"
    case "EnterPlanMode": return "Planning"
    case "ExitPlanMode": return "Plan ready"
    case "AskUserQuestion": return "Asking question"
    default: return "Using tool"
    }
}

func sidebarToolDetailLabel(_ tool: String, detail: String) -> String {
    switch tool {
    case "Bash":
        return summarizeBashCommand(detail)
    case "Read":
        return "reading \(sidebarAbbreviateFilePath(detail))"
    case "Edit":
        return "editing \(sidebarAbbreviateFilePath(detail))"
    case "Write":
        return sidebarAbbreviateFilePath(detail)
    case "Grep":
        return detail
    case "Glob":
        return detail
    case "Agent":
        return detail
    case "WebFetch":
        if let url = URL(string: detail) {
            return url.host ?? detail
        }
        return detail
    case "WebSearch":
        return "\"\(detail)\""
    case "TaskCreate":
        return detail
    case "TaskUpdate":
        return detail
    default:
        return detail
    }
}

func sidebarToolColor(_ tool: String) -> Color {
    switch tool {
    // File / shell / search tools share the same orange treatment so the
    // user's eye doesn't have to juggle a palette for common operations.
    case "Bash", "Read", "Edit", "Write", "Grep", "Glob": return .orange
    case "Agent": return Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.systemYellow
            : NSColor(red: 0.6, green: 0.5, blue: 0.0, alpha: 1)
    })
    case "WebFetch", "WebSearch": return Color(nsColor: .systemTeal)
    case "TaskCreate", "TaskUpdate": return .green
    default: return .blue
    }
}

func sidebarTaskIcon(_ status: String) -> String {
    switch status {
    case "completed": return "checkmark.circle.fill"
    case "in_progress": return "circle.dotted"
    default: return "circle"
    }
}

func sidebarTaskColor(_ status: String) -> Color {
    switch status {
    case "completed": return .green
    case "in_progress": return .blue
    default: return Color(nsColor: .tertiaryLabelColor)
    }
}
