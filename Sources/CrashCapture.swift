import Darwin
import Foundation

/// Immediate, synchronous crash capture — independent of MetricKit (whose
/// MXDiagnosticPayload crash reports are delivered batched ~once per day) and
/// of the system crash store (which on some machines is disabled/purged, so a
/// `.ips` may never persist). Writes to ~/.claude-terminal/diagnostics/crash.log
/// the instant a crash happens, via three channels:
///
///   1. stderr is redirected into the log file, so the Swift runtime's own
///      "Fatal error: … at file.swift:line" message from a force-unwrap /
///      precondition / fatalError() — the most common crash class — is
///      captured verbatim, along with NSLog / assertion output. This alone
///      usually pins the cause. (The app otherwise prints to stdout, which the
///      `cx` launcher sends to /dev/null, so nothing reaches disk today.)
///   2. An uncaught-exception handler records ObjC/Swift exception name,
///      reason, and a symbolicated call stack (runs in normal context — safe
///      to use Foundation).
///   3. POSIX signal handlers (SIGSEGV/SIGABRT/SIGILL/SIGBUS/SIGTRAP/SIGFPE,
///      and SIGPIPE/SIGTERM/SIGHUP, which end the process with no crash
///      report) write the signal number plus a backtrace using only
///      async-signal-safe calls, then re-raise the default handler so any
///      system reporting still fires. They run on an alternate stack, so a
///      stack overflow (a layout or recursion loop) is recorded too: on the
///      overflowed stack the handler itself would fault before writing.
///   4. An atexit handler logs a backtrace when anything calls exit() other
///      than the app's own launch paths (CLI handoff, --help, bad --pref) and
///      a normal quit. It names the caller of an exit nothing else records.
///
/// The log fd is opened once at launch and held for the process lifetime.

private var crashLogFD: Int32 = -1

// Preformatted, allocation-free bytes for the signal path. Built once at
// launch so the signal handler itself never touches the allocator (malloc may
// be corrupt post-SIGSEGV). backtrace_symbols_fd + write are async-signal-safe.
private let crashSignalMarker: [UInt8] = Array("\n*** claude-terminal: fatal signal ".utf8)
private let crashSignalMarkerEnd: [UInt8] = Array(" — backtrace ***\n".utf8)
private let exitMarker: [UInt8] = Array("\n*** claude-terminal: exit() called — backtrace ***\n".utf8)

/// Set before an exit the app means to make (CLI handoff, --help, a normal
/// quit), so the atexit handler logs only unexpected ones.
nonisolated(unsafe) var isExpectedExit = false

/// Preallocated scratch for the signal path: backtrace frames and number
/// digits. A Swift array made inside the handler would allocate.
private let frameBuffer = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 128)
private let digitBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 12)

/// Writes `n` in decimal with no allocation, for the signal path.
private func writeNumber(_ fd: Int32, _ n: Int32) {
    var value = n < 0 ? -Int(n) : Int(n)
    var i = 12
    repeat {
        i -= 1
        digitBuffer[i] = UInt8(48 + value % 10)
        value /= 10
    } while value > 0 && i > 0
    _ = write(fd, digitBuffer + i, 12 - i)
}

private func writeBacktrace(_ fd: Int32) {
    let count = backtrace(frameBuffer, 128)
    backtrace_symbols_fd(frameBuffer, count, fd)
    fsync(fd)
}

private func crashSignalHandler(_ sig: Int32) {
    if crashLogFD >= 0 {
        crashSignalMarker.withUnsafeBytes { _ = write(crashLogFD, $0.baseAddress, $0.count) }
        writeNumber(crashLogFD, sig)
        crashSignalMarkerEnd.withUnsafeBytes { _ = write(crashLogFD, $0.baseAddress, $0.count) }
        writeBacktrace(crashLogFD)
    }
    // Restore the default disposition and re-raise so normal crash handling
    // (and any system reporter) still runs.
    signal(sig, SIG_DFL)
    raise(sig)
}

/// Install crash capture. Call once, as early as possible in `main`, after any
/// re-exec (so it runs in the final process image and reads the correct
/// bundle version).
func installCrashCapture() {
    let home = NSHomeDirectory()
    let dir = (home as NSString).appendingPathComponent(".claude-terminal/diagnostics")
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = (dir as NSString).appendingPathComponent("crash.log")

    // Bound growth: one rotation at ~512 KB. stderr redirection means routine
    // NSLog/warning noise also lands here, so it must not grow unbounded.
    var st = stat()
    if stat(path, &st) == 0, st.st_size > 512 * 1024 {
        rename(path, (path as NSString).appendingPathExtension("1") ?? path + ".1")
    }

    let fd = open(path, O_CREAT | O_WRONLY | O_APPEND, 0o644)
    guard fd >= 0 else { return }
    crashLogFD = fd

    // Route stderr into the log so Swift-runtime fatal messages are captured.
    dup2(fd, STDERR_FILENO)

    // Session header (normal context — Foundation is fine here).
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    let ts = ISO8601DateFormatter().string(from: Date())
    let header = "\n===== launch \(ts)  v\(version) (\(build))  pid \(getpid()) =====\n"
    if let data = header.data(using: .utf8) {
        data.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
    }

    // Uncaught ObjC/Swift exceptions.
    NSSetUncaughtExceptionHandler { exc in
        guard crashLogFD >= 0 else { return }
        var out = "\n*** claude-terminal: uncaught exception ***\n"
        out += "name: \(exc.name.rawValue)\n"
        out += "reason: \(exc.reason ?? "(nil)")\n"
        out += exc.callStackSymbols.joined(separator: "\n")
        out += "\n"
        if let data = out.data(using: .utf8) {
            data.withUnsafeBytes { _ = write(crashLogFD, $0.baseAddress, $0.count) }
        }
        fsync(crashLogFD)
    }

    // An alternate stack for the handlers: a stack overflow leaves no room on
    // the thread's own stack to run one. sigaltstack is per thread, so this
    // covers the main thread, where AppKit and SwiftUI layout run. Allocated
    // once and never freed.
    _ = frameBuffer
    _ = digitBuffer
    let altStackSize = 256 * 1024
    if let base = malloc(altStackSize) {
        var ss = stack_t(ss_sp: base, ss_size: altStackSize, ss_flags: 0)
        sigaltstack(&ss, nil)
    }

    // POSIX signals raised by crashes and Swift traps, and the ones that end
    // the process silently (a write to a closed pipe, a kill, a hangup).
    for sig in [SIGSEGV, SIGABRT, SIGILL, SIGBUS, SIGTRAP, SIGFPE, SIGPIPE, SIGTERM, SIGHUP] {
        var action = sigaction()
        action.__sigaction_u.__sa_handler = crashSignalHandler
        action.sa_flags = SA_ONSTACK
        sigemptyset(&action.sa_mask)
        sigaction(sig, &action, nil)
    }

    atexit {
        guard !isExpectedExit, crashLogFD >= 0 else { return }
        exitMarker.withUnsafeBytes { _ = write(crashLogFD, $0.baseAddress, $0.count) }
        writeBacktrace(crashLogFD)
    }
}
