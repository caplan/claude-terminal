import Foundation

extension AppDelegate {
    private static let dangerDirsKey = "dangerDirs"

    /// True if the user has previously checked "skip danger prompts" for
    /// this working directory. Read at session-launch time to decide
    /// whether to pass `--dangerously-skip-permissions` to Claude Code.
    static func isDangerSavedForDir(_ dir: String) -> Bool {
        let dirs = UserDefaults.standard.stringArray(forKey: dangerDirsKey) ?? []
        return dirs.contains(dir)
    }

    static func setDangerSaved(_ enabled: Bool, forDir dir: String) {
        var dirs = UserDefaults.standard.stringArray(forKey: dangerDirsKey) ?? []
        if enabled {
            if !dirs.contains(dir) { dirs.append(dir) }
        } else {
            dirs.removeAll { $0 == dir }
        }
        UserDefaults.standard.set(dirs, forKey: dangerDirsKey)
    }
}
