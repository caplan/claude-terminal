import Foundation

/// The last model each working directory's session ran on. Claude Code's
/// `--continue` starts on the settings default, so Open Session passes this
/// back with `--model` to resume on the same model.
enum LastModel {
    private static let key = "lastModelByDir"

    static func model(forDir dir: String) -> String? {
        let map = UserDefaults.standard.dictionary(forKey: key) as? [String: String]
        guard let id = map?[dir], isSafe(id) else { return nil }
        return id
    }

    static func save(_ modelId: String, forDir dir: String) {
        guard isSafe(modelId) else { return }
        var map = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        guard map[dir] != modelId else { return }
        map[dir] = modelId
        UserDefaults.standard.set(map, forKey: key)
    }

    /// The `--model` option for a directory, or nil when none is saved.
    /// The id goes into a shell command line, so it is single-quoted and
    /// limited to the characters model ids use.
    static func option(forDir dir: String) -> String? {
        model(forDir: dir).map { "--model '\($0)'" }
    }

    /// Puts the directory's saved model into an option string. Any `--model`
    /// already in the string is removed first, so the saved model wins over
    /// the one the session was first opened with. With no saved model, the
    /// string is returned unchanged.
    static func applying(to opts: String, forDir dir: String) -> String {
        guard let modelOpt = option(forDir: dir) else { return opts }
        let stripped = opts.replacingOccurrences(
            of: #"\s*--model(\s+|=)('[^']*'|"[^"]*"|\S+)"#,
            with: "",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty ? modelOpt : "\(stripped) \(modelOpt)"
    }

    private static func isSafe(_ id: String) -> Bool {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_[]:@")
        return !id.isEmpty && id.count <= 128
            && id.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
