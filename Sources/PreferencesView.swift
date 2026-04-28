import SwiftUI

enum AppearanceMode: String, CaseIterable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    static func current() -> AppearanceMode {
        let raw = UserDefaults.standard.string(forKey: "appearanceMode") ?? "System"
        return AppearanceMode(rawValue: raw) ?? .system
    }

    func apply() {
        UserDefaults.standard.set(rawValue, forKey: "appearanceMode")
        NSApp.appearance = nsAppearance
    }
}

struct PreferencesView: View {
    @State private var fontFamily: String
    @State private var fontSize: Double
    @State private var theme: String
    @State private var customBackground: Color
    @State private var useCustomBackground: Bool
    @State private var sidebarDefaultVisible: Bool
    @State private var notificationsEnabled: Bool
    @State private var appearanceMode: AppearanceMode
    @State private var menuBarIconVisible: Bool
    @State private var menuBarTrigger: String

    private let catalog = ThemeCatalog.shared

    init() {
        let keys: Set<String> = ["font-family", "font-size", "theme", "background"]
        let values = GhosttyConfigFile.readValues(for: keys)

        _fontFamily = State(initialValue: values["font-family"] ?? "")
        _fontSize = State(initialValue: Double(values["font-size"] ?? "") ?? 12)
        _theme = State(initialValue: values["theme"] ?? "")

        if let bgHex = values["background"] {
            _customBackground = State(initialValue: Self.colorFromHex(bgHex) ?? Color(white: 0.1))
            _useCustomBackground = State(initialValue: true)
        } else {
            _customBackground = State(initialValue: Color(white: 0.1))
            _useCustomBackground = State(initialValue: false)
        }

        _sidebarDefaultVisible = State(initialValue: UserDefaults.standard.object(forKey: "sidebarDefaultVisible") as? Bool ?? true)
        _notificationsEnabled = State(initialValue: UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true)
        _appearanceMode = State(initialValue: AppearanceMode.current())
        _menuBarIconVisible = State(initialValue: UserDefaults.standard.object(forKey: "menuBarIconVisible") as? Bool ?? true)
        _menuBarTrigger = State(initialValue: UserDefaults.standard.string(forKey: "menuBarTrigger") ?? "hover")
    }

    private static func colorFromHex(_ hex: String) -> Color? {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6, let rgb = UInt32(cleaned, radix: 16) else { return nil }
        return Color(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }

    var body: some View {
        Form {
            Section("Font") {
                TextField("Font family", text: $fontFamily, prompt: Text("e.g. Menlo, SF Mono"))
                    .onSubmit { applyToTerminal() }
                HStack {
                    Text("Font size")
                    Spacer()
                    TextField("", value: $fontSize, format: .number)
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                        .onSubmit { applyToTerminal() }
                    Stepper("", value: $fontSize, in: 8...72, step: 1)
                        .labelsHidden()
                }
            }

            Section("Appearance") {
                Picker("Mode", selection: $appearanceMode) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .onChange(of: appearanceMode) { _ in
                    appearanceMode.apply()
                    applyToTerminal()
                }

                ThemePopUpButton(
                    selection: $theme,
                    catalog: catalog,
                    onChange: { applyToTerminal() }
                )

                HStack {
                    Toggle("Custom background", isOn: $useCustomBackground)
                        .onChange(of: useCustomBackground) { _ in applyToTerminal() }
                    Spacer()
                    ColorPicker("", selection: $customBackground, supportsOpacity: false)
                        .labelsHidden()
                        .disabled(!useCustomBackground)
                        .onChange(of: customBackground) { _ in
                            if useCustomBackground { applyToTerminal() }
                        }
                }
            }

            Section("Sidebar") {
                Toggle("Show sidebar by default in new windows", isOn: $sidebarDefaultVisible)
            }

            Section("Menu Bar") {
                Toggle("Show icon in menu bar", isOn: $menuBarIconVisible)
                    .onChange(of: menuBarIconVisible) { _ in
                        UserDefaults.standard.set(menuBarIconVisible, forKey: "menuBarIconVisible")
                        AppDelegate.shared?.menuBarController?.updateVisibility()
                    }
                Picker("Show sessions on", selection: $menuBarTrigger) {
                    Text("Click").tag("click")
                    Text("Hover").tag("hover")
                }
                .pickerStyle(.segmented)
                .onChange(of: menuBarTrigger) { _ in
                    UserDefaults.standard.set(menuBarTrigger, forKey: "menuBarTrigger")
                    AppDelegate.shared?.menuBarController?.updateTriggerMode()
                }
            }

            Section("Notifications") {
                Toggle("Notify when Claude needs input", isOn: $notificationsEnabled)
                    .onChange(of: notificationsEnabled) { _ in
                        UserDefaults.standard.set(notificationsEnabled, forKey: "notificationsEnabled")
                        Self.writeNotificationFlag(notificationsEnabled)
                    }
                Text("Sends a macOS notification when Claude is waiting for permission approval or asks a question.")
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: .secondaryLabelColor))
            }
        }
        .formStyle(.grouped)
        .onChange(of: fontSize) { _ in applyToTerminal() }
        .onDisappear { save() }
    }

    private func applyToTerminal() {
        writeConfig()
        GhosttyConfig.invalidateLoadCache()
        GhosttyApp.shared.reloadConfiguration(soft: false, source: "preferences")
    }

    private func save() {
        writeConfig()
        UserDefaults.standard.set(sidebarDefaultVisible, forKey: "sidebarDefaultVisible")
        appearanceMode.apply()
        GhosttyConfig.invalidateLoadCache()
        GhosttyApp.shared.reloadConfiguration(soft: false, source: "preferences")
    }

    private func writeConfig() {
        var updates: [String: String] = [:]
        var remove: Set<String> = ["background-opacity", "scrollback-limit"]
        if !fontFamily.isEmpty {
            updates["font-family"] = fontFamily
        }
        updates["font-size"] = String(Int(fontSize))
        if !theme.isEmpty {
            updates["theme"] = theme
        }
        if useCustomBackground {
            updates["background"] = hexFromColor(customBackground)
        } else {
            remove.insert("background")
        }
        GhosttyConfigFile.writeValues(updates, removeKeys: remove)
    }

    static func writeNotificationFlag(_ enabled: Bool) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = "\(home)/.claude-terminal"
        let path = "\(dir)/notifications-enabled"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if enabled {
            try? "1".write(toFile: path, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private func hexFromColor(_ color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        let r = Int(round(ns.redComponent * 255))
        let g = Int(round(ns.greenComponent * 255))
        let b = Int(round(ns.blueComponent * 255))
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}

struct ThemePopUpButton: NSViewRepresentable {
    @Binding var selection: String
    let catalog: ThemeCatalog
    var onChange: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        buildMenu(button)
        selectItem(in: button)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        selectItem(in: button)
    }

    private func buildMenu(_ button: NSPopUpButton) {
        let menu = NSMenu()

        let defaultItem = NSMenuItem(title: "Default", action: nil, keyEquivalent: "")
        defaultItem.representedObject = "" as String
        menu.addItem(defaultItem)

        menu.addItem(.separator())
        let darkHeader = NSMenuItem(title: "Dark Themes", action: nil, keyEquivalent: "")
        darkHeader.isEnabled = false
        menu.addItem(darkHeader)
        for t in catalog.dark {
            menu.addItem(menuItem(for: t))
        }

        menu.addItem(.separator())
        let lightHeader = NSMenuItem(title: "Light Themes", action: nil, keyEquivalent: "")
        lightHeader.isEnabled = false
        menu.addItem(lightHeader)
        for t in catalog.light {
            menu.addItem(menuItem(for: t))
        }

        button.menu = menu
    }

    private func menuItem(for theme: ThemeCatalog.Theme) -> NSMenuItem {
        let item = NSMenuItem(title: theme.name, action: nil, keyEquivalent: "")
        item.representedObject = theme.id

        let attributed = NSMutableAttributedString(string: " \(theme.name) ", attributes: [
            .font: NSFont.menuFont(ofSize: 13),
            .foregroundColor: NSColor(theme.foregroundColor),
            .backgroundColor: NSColor(theme.backgroundColor),
        ])
        item.attributedTitle = attributed
        return item
    }

    private func selectItem(in button: NSPopUpButton) {
        guard let menu = button.menu else { return }
        for (i, item) in menu.items.enumerated() {
            if (item.representedObject as? String) == selection {
                button.selectItem(at: i)
                return
            }
        }
        button.selectItem(at: 0)
    }

    class Coordinator: NSObject {
        let parent: ThemePopUpButton

        init(_ parent: ThemePopUpButton) {
            self.parent = parent
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            guard let selected = sender.selectedItem?.representedObject as? String else { return }
            if parent.selection != selected {
                parent.selection = selected
                parent.onChange()
            }
        }
    }
}
