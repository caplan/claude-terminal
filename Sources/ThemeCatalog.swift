import Foundation
import SwiftUI

struct ThemeCatalog {
    struct Theme: Identifiable, Comparable {
        let id: String
        var name: String { id }
        let isLight: Bool
        let backgroundColor: Color
        let foregroundColor: Color

        static func < (lhs: Theme, rhs: Theme) -> Bool {
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    let light: [Theme]
    let dark: [Theme]

    static let shared: ThemeCatalog = {
        var lightThemes: [Theme] = []
        var darkThemes: [Theme] = []

        guard let themesURL = Bundle.main.resourceURL?
            .appendingPathComponent("ghostty/themes") else {
            return ThemeCatalog(light: [], dark: [])
        }

        guard let files = try? FileManager.default.contentsOfDirectory(atPath: themesURL.path) else {
            return ThemeCatalog(light: [], dark: [])
        }

        for file in files {
            let path = themesURL.appendingPathComponent(file).path
            let colors = parseThemeColors(atPath: path)
            let theme = Theme(
                id: file,
                isLight: colors.isLight,
                backgroundColor: colors.background,
                foregroundColor: colors.foreground
            )
            if colors.isLight {
                lightThemes.append(theme)
            } else {
                darkThemes.append(theme)
            }
        }

        return ThemeCatalog(light: lightThemes.sorted(), dark: darkThemes.sorted())
    }()

    private static func parseThemeColors(atPath path: String) -> (background: Color, foreground: Color, isLight: Bool) {
        var bg: Color = Color(white: 0.1)
        var fg: Color = Color(white: 0.9)
        var bgLuminance: Double = 0.0

        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return (bg, fg, false)
        }

        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let hex = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            guard hex.count == 6, let rgb = UInt32(hex, radix: 16) else { continue }
            let r = Double((rgb >> 16) & 0xFF) / 255.0
            let g = Double((rgb >> 8) & 0xFF) / 255.0
            let b = Double(rgb & 0xFF) / 255.0

            if key == "background" {
                bg = Color(red: r, green: g, blue: b)
                bgLuminance = 0.299 * r + 0.587 * g + 0.114 * b
            } else if key == "foreground" {
                fg = Color(red: r, green: g, blue: b)
            }
        }

        return (bg, fg, bgLuminance > 0.5)
    }
}
