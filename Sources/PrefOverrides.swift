import Foundation

/// CLI-supplied overrides for user preferences. Values are installed into
/// NSArgumentDomain so they take precedence over the persisted app domain
/// on UserDefaults reads, but are never written to disk — they evaporate
/// when the process exits. The ~30 existing `UserDefaults.standard.*(forKey:)`
/// call sites pick them up automatically.
enum PrefOverrides {
    enum Spec {
        case bool
        case int
        case stringEnum([String])
    }

    /// Allowlist: the six preferences exposed in the Settings UI.
    static let supported: [String: Spec] = [
        "appearanceMode":          .stringEnum(["System", "Light", "Dark"]),
        "sidebarDefaultVisible":   .bool,
        "notificationsEnabled":    .bool,
        "menuBarIconVisible":      .bool,
        "menuBarTrigger":          .stringEnum(["hover", "click"]),
        "contextWasteWindowTurns": .int,
    ]

    /// Parse `["key=value", ...]` into a typed dictionary suitable for
    /// `setVolatileDomain`. On any unknown key or bad value, prints to
    /// stderr and returns nil (caller should `exit(2)`).
    static func parse(_ raw: [String]) -> [String: Any]? {
        var out: [String: Any] = [:]
        for entry in raw {
            guard let eq = entry.firstIndex(of: "=") else {
                stderr("--pref expects key=value, got: \(entry)")
                return nil
            }
            let key = String(entry[..<eq])
            let value = String(entry[entry.index(after: eq)...])
            guard let spec = supported[key] else {
                stderr("unknown preference key: \(key)")
                stderr("supported: \(supported.keys.sorted().joined(separator: ", "))")
                return nil
            }
            switch spec {
            case .bool:
                guard let b = parseBool(value) else {
                    stderr("\(key) requires a boolean (true/false/yes/no/1/0), got: \(value)")
                    return nil
                }
                out[key] = b
            case .int:
                guard let n = Int(value) else {
                    stderr("\(key) requires an integer, got: \(value)")
                    return nil
                }
                out[key] = n
            case .stringEnum(let allowed):
                guard allowed.contains(value) else {
                    stderr("invalid value for \(key) (expected one of: \(allowed.joined(separator: ", "))), got: \(value)")
                    return nil
                }
                out[key] = value
            }
        }
        return out
    }

    /// Merge the parsed overrides into NSArgumentDomain so UserDefaults
    /// reads see them. Preserves any existing argument-domain entries
    /// that the system set up from argv.
    static func install(_ parsed: [String: Any]) {
        guard !parsed.isEmpty else { return }
        let existing = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        let merged = existing.merging(parsed) { _, new in new }
        UserDefaults.standard.setVolatileDomain(merged, forName: UserDefaults.argumentDomain)
    }

    private static func parseBool(_ s: String) -> Bool? {
        switch s.lowercased() {
        case "true", "yes", "1", "y": return true
        case "false", "no", "0", "n": return false
        default: return nil
        }
    }

    private static func stderr(_ message: String) {
        FileHandle.standardError.write(Data("claude-terminal: \(message)\n".utf8))
    }
}
