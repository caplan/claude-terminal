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
///   3. POSIX signal handlers (SIGSEGV/SIGABRT/SIGILL/SIGBUS/SIGTRAP/SIGFPE)
///      write a fixed marker plus a backtrace using only async-signal-safe
///      calls, then re-raise the default handler so any system reporting still
///      fires.
///
/// The log fd is opened once at launch and held for the process lifetime.

private var crashLogFD: Int32 = -1

// Preformatted, allocation-free bytes for the signal path. Built once at
// launch so the signal handler itself never touches the allocator (malloc may
// be corrupt post-SIGSEGV). backtrace_symbols_fd + write are async-signal-safe.
private let crashSignalMarker: [UInt8] = Array("\n*** claude-terminal: fatal signal — backtrace ***\n".utf8)

private func crashSignalHandler(_ sig: Int32) {
    if crashLogFD >= 0 {
        crashSignalMarker.withUnsafeBytes { _ = write(crashLogFD, $0.baseAddress, $0.count) }
        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
        let count = backtrace(&frames, 128)
        backtrace_symbols_fd(&frames, count, crashLogFD)
        fsync(crashLogFD)
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

    // POSIX signals commonly raised by crashes and Swift traps.
    for sig in [SIGSEGV, SIGABRT, SIGILL, SIGBUS, SIGTRAP, SIGFPE] {
        signal(sig, crashSignalHandler)
    }
}
