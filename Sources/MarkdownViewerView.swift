import SwiftUI
import WebKit

struct MarkdownViewerView: NSViewRepresentable {
    let path: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.load(path: path)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.webView = nsView
        context.coordinator.load(path: path)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.stopWatching()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        private var currentPath: String?
        private var isHarnessLoaded = false
        private var pendingSource: String?
        private var fileDescriptor: Int32 = -1
        private var dispatchSource: DispatchSourceFileSystemObject?
        private let watchQueue = DispatchQueue(label: "org.claire.claude-terminal.md-viewer", qos: .utility)

        func load(path: String) {
            guard path != currentPath else { return }
            currentPath = path
            stopWatching()

            if !isHarnessLoaded {
                loadHarness()
            }
            renderFromDisk()
            startWatching(path: path)
        }

        private func loadHarness() {
            guard let url = Bundle.main.url(
                forResource: "viewer",
                withExtension: "html",
                subdirectory: "markdown-viewer"
            ) else {
                return
            }
            let dir = url.deletingLastPathComponent()
            webView?.loadFileURL(url, allowingReadAccessTo: dir)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isHarnessLoaded = true
            if let src = pendingSource {
                pendingSource = nil
                evaluateRender(source: src)
            }
        }

        private func renderFromDisk() {
            guard let path = currentPath else { return }
            let url = URL(fileURLWithPath: path)
            let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if isHarnessLoaded {
                evaluateRender(source: source)
            } else {
                pendingSource = source
            }
        }

        private func evaluateRender(source: String) {
            guard let webView = webView else { return }
            let encoded: Data
            do {
                encoded = try JSONSerialization.data(withJSONObject: [source], options: [])
            } catch {
                return
            }
            guard let jsonArray = String(data: encoded, encoding: .utf8) else { return }
            // jsonArray is e.g. ["hello **world**"], pull the first element.
            let js = "window.render(\(jsonArray)[0]);"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        private func startWatching(path: String) {
            watchQueue.async { [weak self] in
                guard let self else { return }
                let fd = open(path, O_EVTONLY)
                guard fd >= 0 else { return }
                self.fileDescriptor = fd
                let src = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: fd,
                    eventMask: [.write, .rename, .delete, .extend],
                    queue: self.watchQueue
                )
                src.setEventHandler { [weak self] in
                    guard let self else { return }
                    let event = src.data
                    if event.contains(.delete) || event.contains(.rename) {
                        // File was replaced by atomic rename (common for editors).
                        // Reattach shortly after.
                        self.watchQueue.asyncAfter(deadline: .now() + 0.1) {
                            guard let path = self.currentPath else { return }
                            self.stopWatching()
                            DispatchQueue.main.async { self.renderFromDisk() }
                            self.startWatching(path: path)
                        }
                    } else {
                        DispatchQueue.main.async { self.renderFromDisk() }
                    }
                }
                src.setCancelHandler { [weak self] in
                    guard let self else { return }
                    if self.fileDescriptor >= 0 {
                        close(self.fileDescriptor)
                        self.fileDescriptor = -1
                    }
                }
                src.resume()
                self.dispatchSource = src
            }
        }

        func stopWatching() {
            dispatchSource?.cancel()
            dispatchSource = nil
        }
    }
}
