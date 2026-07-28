import Foundation

struct JiraTicket {
    let key: String
    let title: String?
    let url: URL

    var displayText: String { title ?? key }
}

enum JiraTicketDetector {
    private static var cache: [String: JiraTicket?] = [:]
    private static var titleCache: [String: String] = [:]
    private static var branchKeyCache: [String: String?] = [:]
    private static var baseURL: String?
    private static var baseURLResolved = false
    private static var jiraPath: String?
    private static var jiraPathResolved = false

    static func ticket(for directory: String) -> JiraTicket? {
        if let fromFile = readTicketFile(in: directory) {
            return fromFile
        }
        if let cached = cache[directory] { return cached }
        let result = detect(in: directory)
        if result?.title != nil {
            cache[directory] = result
        }
        return result
    }

    private static func detect(in directory: String) -> JiraTicket? {
        if branchKeyCache[directory] == nil {
            branchKeyCache[directory] = extractTicketFromBranch(in: directory)
        }
        guard let ticketKey = branchKeyCache[directory] ?? nil else { return nil }
        return buildTicket(key: ticketKey)
    }

    private static func readTicketFile(in directory: String) -> JiraTicket? {
        let path = (directory as NSString).appendingPathComponent(".jira-ticket")
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let key = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = try? NSRegularExpression(pattern: "^[A-Z][A-Z0-9]+-\\d+$")
        let range = NSRange(key.startIndex..., in: key)
        guard pattern?.firstMatch(in: key, range: range) != nil else { return nil }
        return buildTicket(key: key)
    }

    private static func buildTicket(key: String) -> JiraTicket? {
        guard let base = resolveBaseURL() else { return nil }
        guard let url = URL(string: "\(base)/browse/\(key)") else { return nil }
        if let cached = titleCache[key] {
            return JiraTicket(key: key, title: cached, url: url)
        }
        let ticket = JiraTicket(key: key, title: nil, url: url)
        DispatchQueue.global(qos: .userInitiated).async {
            if let title = fetchTitle(for: key) {
                titleCache[key] = title
            }
        }
        return ticket
    }

    private static var gitPath: String?
    private static var gitPathResolved = false

    private static func resolveGitPath() -> String? {
        if gitPathResolved { return gitPath }
        gitPathResolved = true
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["git"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        gitPath = path.isEmpty ? nil : path
        return gitPath
    }

    private static func extractTicketFromBranch(in directory: String) -> String? {
        guard let git = resolveGitPath() else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: git)
        proc.arguments = ["-C", directory, "rev-parse", "--abbrev-ref", "HEAD"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let branch = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !branch.isEmpty else { return nil }

        let pattern = try? NSRegularExpression(pattern: "[A-Z][A-Z0-9]+-\\d+")
        let range = NSRange(branch.startIndex..., in: branch)
        guard let match = pattern?.firstMatch(in: branch, range: range) else { return nil }
        return String(branch[Range(match.range, in: branch)!])
    }

    private static func fetchTitle(for ticketKey: String) -> String? {
        guard let jira = resolveJiraPath() else { return nil }

        // jira-cli (ankitpokhrel/jira-cli): `jira issue view KEY --raw`
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: jira)
        proc.arguments = ["issue", "view", ticketKey, "--raw"]
        if let env = AppDelegate.shared?.userShellEnvironment {
            proc.environment = env
        }
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        if proc.terminationStatus == 0 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let fields = json["fields"] as? [String: Any],
               let summary = fields["summary"] as? String,
               !summary.isEmpty {
                return summary
            }
        }

        // Fallback: go-jira `jira view KEY --gjq fields.summary`
        let proc2 = Process()
        proc2.executableURL = URL(fileURLWithPath: jira)
        proc2.arguments = ["view", ticketKey, "--gjq", "fields.summary"]
        if let env = AppDelegate.shared?.userShellEnvironment {
            proc2.environment = env
        }
        let pipe2 = Pipe()
        proc2.standardOutput = pipe2
        proc2.standardError = FileHandle.nullDevice
        do { try proc2.run() } catch { return nil }
        let data2 = pipe2.fileHandleForReading.readDataToEndOfFile()
        proc2.waitUntilExit()
        guard proc2.terminationStatus == 0 else { return nil }
        let title = String(data: data2, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? nil : title
    }

    private static func resolveJiraPath() -> String? {
        if jiraPathResolved { return jiraPath }
        jiraPathResolved = true

        let candidates = [
            "/opt/homebrew/bin/jira",
            "/usr/local/bin/jira",
        ]
        let fm = FileManager.default
        for path in candidates {
            if fm.isExecutableFile(atPath: path) {
                jiraPath = path
                return jiraPath
            }
        }

        if let userEnv = AppDelegate.shared?.userShellEnvironment?["PATH"] {
            for dir in userEnv.split(separator: ":") {
                let path = "\(dir)/jira"
                if fm.isExecutableFile(atPath: path) {
                    jiraPath = path
                    return jiraPath
                }
            }
        }

        return nil
    }

    private static func resolveBaseURL() -> String? {
        if baseURLResolved { return baseURL }
        baseURLResolved = true

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let configPaths = [
            "\(home)/.config/.jira/.config.yml",
            "\(home)/.jira.d/config.yml",
        ]
        for configPath in configPaths {
            guard let contents = try? String(contentsOfFile: configPath, encoding: .utf8) else { continue }
            for line in contents.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("server:") {
                    let value = trimmed.dropFirst("server:".count).trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty {
                        baseURL = value
                        return baseURL
                    }
                }
            }
        }

        if let envURL = ProcessInfo.processInfo.environment["JIRA_URL"] {
            baseURL = envURL
            return baseURL
        }

        return nil
    }

    static var isJiraAvailable: Bool { resolveBaseURL() != nil }
    static var isJiraCLIAvailable: Bool { resolveJiraPath() != nil }
}
