import Foundation

enum GhosttyConfigFile {
    static let defaultPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.config/ghostty/config"
    }()

    static func readValues(for keys: Set<String>, at path: String = defaultPath) -> [String: String] {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            if keys.contains(key) {
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                result[key] = value
            }
        }
        return result
    }

    static func writeValues(_ updates: [String: String], removeKeys: Set<String> = [], at path: String = defaultPath) {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let existingLines: [String]
        if let contents = try? String(contentsOfFile: path, encoding: .utf8) {
            existingLines = contents.components(separatedBy: "\n")
        } else {
            existingLines = []
        }

        var handled = Set<String>()
        var outputLines: [String] = []

        for line in existingLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                let parts = trimmed.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    let key = parts[0].trimmingCharacters(in: .whitespaces)
                    if removeKeys.contains(key) {
                        continue
                    }
                    if let newValue = updates[key] {
                        outputLines.append("\(key) = \(newValue)")
                        handled.insert(key)
                        continue
                    }
                }
            }
            outputLines.append(line)
        }

        for (key, value) in updates where !handled.contains(key) {
            outputLines.append("\(key) = \(value)")
        }

        // Remove trailing empty lines, then ensure single newline at end
        while let last = outputLines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            outputLines.removeLast()
        }

        let output = outputLines.joined(separator: "\n") + "\n"
        try? output.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
