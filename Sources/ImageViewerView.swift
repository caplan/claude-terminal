import SwiftUI
import AppKit

/// Static image viewer shown in the same tab area as MarkdownViewerView.
/// Re-reads the file on disk changes via DispatchSource so save-from-Photoshop
/// / Claude rewriting an image / etc. refreshes the view automatically.
struct ImageViewerView: NSViewRepresentable {
    let tabId: UUID
    let path: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.1
        scroll.maxMagnification = 8
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear

        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        image.imageAlignment = .alignCenter
        image.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = image
        context.coordinator.imageView = image
        context.coordinator.scrollView = scroll
        context.coordinator.load(path: path)
        context.coordinator.startWatching(path: path)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if context.coordinator.currentPath != path {
            context.coordinator.load(path: path)
            context.coordinator.startWatching(path: path)
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.stopWatching()
    }

    final class Coordinator {
        weak var imageView: NSImageView?
        weak var scrollView: NSScrollView?
        var currentPath: String?

        private var fd: Int32 = -1
        private var source: DispatchSourceFileSystemObject?
        private let queue = DispatchQueue(label: "org.claire.claude-terminal.image-viewer", qos: .utility)

        func load(path: String) {
            currentPath = path
            guard let imageView, let scrollView else { return }
            let url = URL(fileURLWithPath: path)
            let img = NSImage(contentsOf: url)
            imageView.image = img
            if let img {
                let size = img.size
                imageView.frame = NSRect(origin: .zero, size: size)
                imageView.setFrameSize(size)
                let visible = scrollView.contentView.bounds.size
                if visible.width > 0, visible.height > 0,
                   size.width > 0, size.height > 0 {
                    let fit = min(visible.width / size.width, visible.height / size.height, 1.0)
                    scrollView.magnification = fit
                }
            }
        }

        func startWatching(path: String) {
            stopWatching()
            queue.async { [weak self] in
                guard let self else { return }
                let f = open(path, O_EVTONLY)
                guard f >= 0 else { return }
                self.fd = f
                let src = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: f,
                    eventMask: [.write, .extend, .rename, .delete],
                    queue: self.queue
                )
                src.setEventHandler { [weak self] in
                    guard let self else { return }
                    let event = src.data
                    if event.contains(.delete) || event.contains(.rename) {
                        // Atomic save replaced the file; reattach + reload.
                        self.queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                            guard let self, let p = self.currentPath else { return }
                            DispatchQueue.main.async { self.load(path: p) }
                            self.startWatching(path: p)
                        }
                    } else {
                        DispatchQueue.main.async { [weak self] in
                            guard let self, let p = self.currentPath else { return }
                            self.load(path: p)
                        }
                    }
                }
                src.setCancelHandler { [weak self] in
                    guard let self, self.fd >= 0 else { return }
                    close(self.fd); self.fd = -1
                }
                src.resume()
                self.source = src
            }
        }

        func stopWatching() {
            queue.async { [weak self] in
                self?.source?.cancel()
                self?.source = nil
            }
        }
    }
}

/// Async thumbnail used in the Documents sidebar. Decodes off the main
/// thread, refreshes on disk changes, and falls back to a placeholder while
/// the image loads or if it fails to decode.
struct ImageThumbnail: View {
    let path: String

    @State private var image: NSImage?
    @State private var pathLoaded: String?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.25))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "photo")
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
            }
        }
        .onAppear { load() }
        .onChange(of: path) { _ in load() }
    }

    private func load() {
        guard pathLoaded != path else { return }
        pathLoaded = path
        let target = path
        DispatchQueue.global(qos: .userInitiated).async {
            let img = NSImage(contentsOfFile: target)
            DispatchQueue.main.async {
                guard pathLoaded == target else { return }
                self.image = img
            }
        }
    }
}

enum ViewableDocument {
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif",
        "webp", "heic", "heif", "svg", "ico", "avif",
    ]
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown"]

    static func isImage(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return imageExtensions.contains(ext)
    }

    static func isMarkdown(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return markdownExtensions.contains(ext)
    }

    static func isViewable(_ path: String) -> Bool {
        isImage(path) || isMarkdown(path)
    }
}
