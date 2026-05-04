import Foundation
import Combine

/// Polls https://www.githubstatus.com/api/v2/status.json every 30 seconds
/// with a 500 ms request timeout. One shared instance fans out to every
/// SidebarView via `@ObservedObject` so we issue a single network call
/// regardless of how many sidebar windows are open.
final class GitHubStatusMonitor: ObservableObject {
    static let shared = GitHubStatusMonitor()

    /// Values the API returns under `status.indicator`. `unknown` is our
    /// own sentinel for network failure / timeout / parse error.
    enum Indicator: String {
        case none           // "All Systems Operational"
        case minor          // yellow
        case major          // orange
        case critical       // red
        case maintenance    // blue
        case unknown        // grey — fetch failed
    }

    @Published private(set) var indicator: Indicator = .unknown
    /// Human-readable status text, e.g. "All Systems Operational" or
    /// "Incident with Issues and Webhooks". Surfaced as the hover tooltip.
    @Published private(set) var summary: String = ""

    private let url = URL(string: "https://www.githubstatus.com/api/v2/status.json")!
    private let session: URLSession
    private var timer: Timer?

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.5
        config.timeoutIntervalForResource = 1.0
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
        start()
    }

    private func start() {
        fetch()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.fetch()
        }
    }

    private func fetch() {
        let task = session.dataTask(with: url) { [weak self] data, _, error in
            guard let self else { return }
            guard error == nil,
                  let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = obj["status"] as? [String: Any],
                  let indicatorStr = status["indicator"] as? String else {
                DispatchQueue.main.async { [weak self] in
                    self?.indicator = .unknown
                    self?.summary = ""
                }
                return
            }
            let parsed = Indicator(rawValue: indicatorStr) ?? .unknown
            let desc = (status["description"] as? String) ?? ""
            DispatchQueue.main.async { [weak self] in
                self?.indicator = parsed
                self?.summary = desc
            }
        }
        task.resume()
    }
}

/// Cached check for "is this directory inside a git repo." The walk-up
/// stops at the first `.git` entry it finds; results memoize by cwd so a
/// repeated lookup is a dictionary hit. Safe to call from the main thread.
enum GitRepoDetector {
    private static var cache: [String: Bool] = [:]

    static func isInGitRepo(_ path: String) -> Bool {
        if let cached = cache[path] { return cached }
        let fm = FileManager.default
        var current = (path as NSString).standardizingPath
        while !current.isEmpty && current != "/" {
            if fm.fileExists(atPath: "\(current)/.git") {
                cache[path] = true
                return true
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        cache[path] = false
        return false
    }
}
