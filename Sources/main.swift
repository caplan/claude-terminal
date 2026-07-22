import AppKit
import Darwin

// When launched through a symlink on $PATH (e.g. /usr/local/bin/claude-terminal →
// Contents/MacOS/claude-terminal), dyld reports the *symlink* path as the executable,
// so Bundle.main resolves to the symlink's directory (e.g. /usr/local/bin) instead of
// the .app. That breaks Sparkle ("updater failed to start", host name shown as "bin")
// and any other bundle-relative lookup. Re-exec from the real in-bundle executable so
// Bundle.main points at the .app. Must run before anything reads Bundle.main or starts
// NSApplication.
func reexecFromAppBundleIfNeeded() {
    // Already resolved to a real .app bundle, or we've already re-exec'd once.
    guard Bundle.main.bundleURL.pathExtension != "app" else { return }
    guard ProcessInfo.processInfo.environment["CLAUDE_TERMINAL_REEXEC"] == nil else { return }

    // Canonical on-disk path of this executable, with symlinks resolved.
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    var rawPath = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&rawPath, &size) == 0 else { return }
    var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(rawPath, &resolved) != nil else { return }
    let realExe = String(cString: resolved)

    // Only re-exec if the real executable actually lives inside a .app bundle.
    guard realExe.contains(".app/Contents/MacOS/") else { return }

    setenv("CLAUDE_TERMINAL_REEXEC", "1", 1)
    var argv = CommandLine.arguments
    argv[0] = realExe
    var cArgv = argv.map { strdup($0) }
    cArgv.append(nil)
    execv(realExe, &cArgv)
    // execv only returns on failure; fall through and run as-is.
    cArgv.forEach { free($0) }
    unsetenv("CLAUDE_TERMINAL_REEXEC")
}

reexecFromAppBundleIfNeeded()

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

// Single-instance lock, held for the whole process lifetime by the primary
// instance. Any later launch that can't acquire it *definitively* knows
// another instance is live — unlike the NSRunningApplication check below,
// which queries LaunchServices state at the very top of startup (before this
// process becomes a GUI app) and can transiently miss a running instance.
// When it does, the new process falls through to app.run() and becomes a
// second .regular app under the same bundle id; the two collide in the
// WindowServer and the older one — holding all its session windows — gets
// torn down with no crash. The lock closes that race. The fd is deliberately
// never closed: it must stay held until the process dies (the kernel then
// releases the flock automatically).
var singleInstanceLockFD: Int32 = -1

func acquireSingleInstanceLock() -> Bool {
    let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude-terminal")
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = (dir as NSString).appendingPathComponent("instance.lock")
    let fd = open(path, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { return true }  // lock infra unavailable → don't block launch
    if flock(fd, LOCK_EX | LOCK_NB) == 0 {
        singleInstanceLockFD = fd  // hold for the process lifetime
        return true
    }
    close(fd)
    return false  // another instance holds the lock
}

// Forward this invocation to the already-running instance (open a new window
// there) and exit. Used both when LaunchServices sees a live instance and
// when the single-instance lock is already held.
func forwardToRunningInstanceAndExit(_ cliArgs: CLIArguments?) -> Never {
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

// If the app is already running, hand off to it and exit. Two independent
// signals, so a miss by either still routes correctly: LaunchServices (fast,
// but racy at startup) OR failure to grab the single-instance lock (race-free
// once both instances are on this version). The OR also keeps working against
// an older primary that predates the lock — LaunchServices still sees it.
let bundleId = Bundle.main.bundleIdentifier ?? "org.claire.claude-terminal"
let anotherInstanceViaLS = NSRunningApplication
    .runningApplications(withBundleIdentifier: bundleId)
    .contains(where: { $0 != .current })
let gotSingleInstanceLock = acquireSingleInstanceLock()
if anotherInstanceViaLS || !gotSingleInstanceLock {
    forwardToRunningInstanceAndExit(cliArgs)
}

// Fresh launch: install overrides into NSArgumentDomain before AppDelegate
// reads any preference.
if let parsedOverrides { PrefOverrides.install(parsedOverrides) }

let app = NSApplication.shared
let delegate = AppDelegate()
delegate.cliArguments = cliArgs
app.delegate = delegate
app.run()
