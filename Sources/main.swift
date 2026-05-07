import AppKit

struct CLIArguments {
    var workingDirectory: String?
    var name: String?
    var claudePassthrough: [String] = []
    var prefOverrides: [String] = []

    var claudeOptions: String? {
        var parts: [String] = []
        if let name { parts.append("--name \"\(name)\"") }
        parts.append(contentsOf: claudePassthrough)
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

func parseCLIArguments() -> CLIArguments? {
    let args = ProcessInfo.processInfo.arguments
    guard args.count > 1 else { return nil }

    var result = CLIArguments()
    var i = 1
    while i < args.count {
        let arg = args[i]
        if arg == "--" {
            result.claudePassthrough = Array(args[(i + 1)...])
            break
        }
        switch arg {
        case "-h", "--help":
            let usage = """
            Usage: claude-terminal [options] [directory] [-- claude-args...]

            Options:
              --name <name>           Session name
              --pref <key>=<value>    Override a preference for this run only (repeatable).
                                      Not written to saved prefs. Supported keys:
                                        appearanceMode          System | Light | Dark
                                        sidebarDefaultVisible   true | false
                                        notificationsEnabled    true | false
                                        menuBarIconVisible      true | false
                                        menuBarTrigger          hover | click
                                        contextWasteWindowTurns <integer>
              -h, --help              Show this help

            Arguments after -- are passed directly to the Claude CLI.
            """
            print(usage)
            exit(0)
        case "--name":
            i += 1
            if i < args.count { result.name = args[i] }
        case "--pref":
            i += 1
            if i < args.count { result.prefOverrides.append(args[i]) }
        default:
            if !arg.hasPrefix("-") {
                var path = arg
                if !path.hasPrefix("/") {
                    path = FileManager.default.currentDirectoryPath + "/" + path
                }
                result.workingDirectory = (path as NSString).standardizingPath
            }
        }
        i += 1
    }
    return result
}

let cliArgs = parseCLIArguments()

// Validate --pref entries up front so both launch paths bail on bad input
// before the app starts or sends a URL.
let parsedOverrides: [String: Any]? = {
    guard let raw = cliArgs?.prefOverrides, !raw.isEmpty else { return nil }
    guard let parsed = PrefOverrides.parse(raw) else { exit(2) }
    return parsed
}()

// If the app is already running, send it a URL to open a new window and exit
let bundleId = Bundle.main.bundleIdentifier ?? "org.claire.claude-terminal"
if NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).contains(where: { $0 != .current }) {
    var components = URLComponents()
    components.scheme = "claude-terminal"
    components.host = "open"
    var queryItems: [URLQueryItem] = []
    let dir = cliArgs?.workingDirectory ?? FileManager.default.currentDirectoryPath
    queryItems.append(URLQueryItem(name: "dir", value: dir))
    if let opts = cliArgs?.claudeOptions {
        queryItems.append(URLQueryItem(name: "claude-options", value: opts))
    }
    for entry in cliArgs?.prefOverrides ?? [] {
        queryItems.append(URLQueryItem(name: "pref", value: entry))
    }
    components.queryItems = queryItems
    if let url = components.url {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = [url.absoluteString]
        try? proc.run()
        proc.waitUntilExit()
    }
    exit(0)
}

// Fresh launch: install overrides into NSArgumentDomain before AppDelegate
// reads any preference.
if let parsedOverrides { PrefOverrides.install(parsedOverrides) }

let app = NSApplication.shared
let delegate = AppDelegate()
delegate.cliArguments = cliArgs
app.delegate = delegate
app.run()
