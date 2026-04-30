import Foundation
import WebKit

struct DocumentTab: Identifiable, Equatable {
    let id: UUID
    var path: String
    var title: String
}

final class DocumentTabState: ObservableObject {
    @Published var tabs: [DocumentTab] = []
    @Published var active: UUID? = nil

    @Published var findActive: Bool = false
    @Published var findQuery: String = ""

    // App-wide page zoom for the markdown viewer, 1.0 = 100%. Persisted in
    // UserDefaults; each DocumentTabState loads the shared value on init and
    // writes back on change.
    @Published var zoomLevel: Double = {
        let saved = UserDefaults.standard.double(forKey: "markdownZoomLevel")
        return saved > 0 ? saved : 1.0
    }() {
        didSet {
            UserDefaults.standard.set(zoomLevel, forKey: "markdownZoomLevel")
        }
    }

    func zoomIn() {
        zoomLevel = min(3.0, zoomLevel + 0.1)
    }

    func zoomOut() {
        zoomLevel = max(0.5, zoomLevel - 0.1)
    }

    func zoomReset() {
        zoomLevel = 1.0
    }

    // Set by whichever MarkdownViewerView is currently visible so the
    // find bar / menu shortcuts can drive its WKWebView.
    weak var activeWebView: WKWebView?

    // Live scroll position per open tab, updated by the viewer. Not
    // @Published — we don't want a SwiftUI re-render on every scroll tick.
    var liveScroll: [UUID: Double] = [:]

    // Populated during session restore so the first render of a given doc
    // applies the previously-saved scrollY. Consumed on first use.
    var pendingRestore: [String: Double] = [:]

    func recordScroll(tabId: UUID, y: Double) {
        liveScroll[tabId] = y
    }

    func takePendingRestore(forPath path: String) -> Double? {
        pendingRestore.removeValue(forKey: path)
    }

    func open(path: String) {
        if let existing = tabs.first(where: { $0.path == path }) {
            active = existing.id
            return
        }
        let tab = DocumentTab(id: UUID(), path: path, title: (path as NSString).lastPathComponent)
        tabs.append(tab)
        active = tab.id
    }

    func close(id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = (active == id)
        tabs.remove(at: idx)
        if wasActive {
            active = nil
            findActive = false
        }
    }

    func activate(_ id: UUID?) {
        active = id
        if id == nil { findActive = false }
    }

    func find(_ query: String, backwards: Bool = false) {
        guard !query.isEmpty, let webView = activeWebView else { return }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.caseSensitive = false
        config.wraps = true
        Task { @MainActor in
            _ = try? await webView.find(query, configuration: config)
        }
    }

    func triggerFind() {
        guard active != nil else { return }
        findActive = true
    }

    func findNext(backwards: Bool) {
        guard findActive, !findQuery.isEmpty else { return }
        find(findQuery, backwards: backwards)
    }
}
