import AppKit
import Foundation
import MetricKit

extension AppDelegate: MXMetricManagerSubscriber {
    /// Subscribes to MetricKit. Payloads arrive once per day, batched by the
    /// system, and are written as JSON under
    /// ~/.claude-terminal/diagnostics/. No upload, no UI — just on-disk
    /// records for after-the-fact inspection.
    func startCrashReporting() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            write(data: payload.jsonRepresentation(), kind: "metric", at: payload.timeStampEnd)
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            write(data: payload.jsonRepresentation(), kind: "diagnostic", at: payload.timeStampEnd)
        }
    }

    private func write(data: Data, kind: String, at date: Date) {
        let dir = Self.diagnosticsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let stamp = Self.filenameFormatter.string(from: date)
        let url = dir.appendingPathComponent("\(stamp)-\(kind).json")
        try? data.write(to: url, options: .atomic)
    }

    /// Opens ~/.claude-terminal/diagnostics in Finder. Creates the directory
    /// first so it's never a silent no-op on a clean install. If MetricKit
    /// has already dropped a payload, the newest one is selected.
    @objc func revealDiagnostics() {
        let dir = Self.diagnosticsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let newest = contents.max { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l < r
        }

        if let newest = newest {
            NSWorkspace.shared.activateFileViewerSelecting([newest])
        } else {
            NSWorkspace.shared.open(dir)
        }
    }

    static var diagnosticsDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude-terminal/diagnostics", isDirectory: true)
    }

    private static let filenameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
