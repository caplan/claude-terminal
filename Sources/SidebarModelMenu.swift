import SwiftUI

/// The model name in the sidebar header, as a menu that switches the session's
/// model and effort. Each pick asks the session's mod to run `/model` or
/// `/effort`, for this session only, as typing it would. Claude Code runs it
/// once the session is idle, so a pick made during a turn applies after it.
struct SidebarModelMenu: View {
    let modelId: String
    let effortLevel: String?
    let defaultModel: String?
    let sessionId: UUID

    /// The four models the menu lists first, by the alias `/model` takes.
    private static let mainModels: [(alias: String, name: String)] = [
        ("opus", "Opus"), ("fable", "Fable"), ("sonnet", "Sonnet"), ("haiku", "Haiku"),
    ]

    /// Under More models: the 1M-context variants, Opus Plan and the saved default.
    private static let moreModels: [(alias: String, name: String)] = [
        ("opus[1m]", "Opus (1M context)"),
        ("sonnet[1m]", "Sonnet (1M context)"),
        ("opusplan", "Opus Plan"),
        ("default", "Default from settings"),
    ]

    private static let efforts: [(level: String, name: String)] = [
        ("low", "Low"), ("medium", "Medium"), ("high", "High"), ("xhigh", "Extra"), ("max", "Max"),
    ]

    var body: some View {
        Menu {
            Section("Model · this session") {
                ForEach(Array(Self.mainModels.enumerated()), id: \.offset) { index, model in
                    Button {
                        send("model", model.alias)
                    } label: {
                        let title = title(for: model.alias, name: model.name)
                        let isDefault = Self.family(of: defaultModel ?? "") == model.alias
                        if family == model.alias && !hasLongContext {
                            Label(isDefault ? "\(title)  (Default)" : title, systemImage: "checkmark")
                        } else {
                            Text(isDefault ? "\(title)  (Default)" : title)
                        }
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [])
                }
            }
            Divider()
            Menu {
                ForEach(Self.efforts, id: \.level) { effort in
                    Button {
                        send("effort", effort.level)
                    } label: {
                        if effort.level == effortLevel {
                            Label(effort.name, systemImage: "checkmark")
                        } else {
                            Text(effort.name)
                        }
                    }
                }
            } label: {
                Text("Effort  \(effortName ?? "")")
            }
            Divider()
            Menu("More models") {
                ForEach(Self.moreModels, id: \.alias) { model in
                    Button {
                        send("model", model.alias)
                    } label: {
                        if isCurrent(model.alias) {
                            Label(model.name, systemImage: "checkmark")
                        } else {
                            Text(model.name)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(Self.displayName(modelId))
                    .foregroundColor(Color(nsColor: .secondaryLabelColor))
                if let effortName {
                    Text(effortName)
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                }
            }
            .font(.system(size: 13))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .help("Switch this session's model or effort. A switch made during a turn applies when the turn ends.")
    }

    private var family: String? { Self.family(of: modelId) }

    private var hasLongContext: Bool { modelId.lowercased().contains("[1m]") }

    private var effortName: String? {
        guard let effortLevel else { return nil }
        return Self.efforts.first { $0.level == effortLevel }?.name ?? effortLevel
    }

    private func isCurrent(_ alias: String) -> Bool {
        switch alias {
        case "opus[1m]": return family == "opus" && hasLongContext
        case "sonnet[1m]": return family == "sonnet" && hasLongContext
        default: return false
        }
    }

    private func send(_ action: String, _ value: String) {
        ClaudeCodeIntegration.sendModRequest(action, value: value, sessionId: sessionId)
    }

    /// The alias family of a model id or alias: `claude-opus-5-5[1m]` is `opus`.
    static func family(of model: String) -> String? {
        let lower = model.lowercased()
        if lower == "opusplan" { return nil }
        return mainModels.first { lower.contains($0.alias) }?.alias
    }

    /// The version in a full id: `claude-sonnet-5-5` is `5.5`.
    private static func version(of model: String) -> String? {
        let base = model.lowercased().replacingOccurrences(of: "[1m]", with: "")
        guard let family = family(of: base),
              let range = base.range(of: "\(family)-") else { return nil }
        let rest = base[range.upperBound...].split(separator: "-").prefix(2)
        guard !rest.isEmpty, rest.allSatisfy({ Int($0) != nil }) else { return nil }
        return rest.joined(separator: ".")
    }

    /// A model's menu title. The current model's version is the only one the
    /// app knows, so only its row shows one: `Opus 5.5`, then `Sonnet`.
    private func title(for alias: String, name: String) -> String {
        guard family == alias, let version = Self.version(of: modelId) else { return name }
        return "\(name) \(version)"
    }

    /// What the header shows: `claude-opus-5-5[1m]` as `Opus 5.5 (1M)`.
    static func displayName(_ model: String) -> String {
        guard let family = family(of: model),
              let name = mainModels.first(where: { $0.alias == family })?.name else { return model }
        var text = name
        if let version = version(of: model) { text += " \(version)" }
        if model.lowercased().contains("[1m]") { text += " (1M)" }
        return text
    }
}
