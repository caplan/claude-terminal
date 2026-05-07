import AppKit
import SwiftUI

/// Section card content — list of documents the user has dropped in or
/// opened from the terminal. Top `fullCount` rows render with title +
/// excerpt; the rest fall back to a compact single-line form to fit the
/// viewport. Single click opens markdown/images in a tab; everything else
/// goes to the OS default app. Right-click exposes Open With… and Show in
/// Finder. The section header is a button that toggles a global
/// @AppStorage("documentsCollapsed") flag.
struct DocumentsSection<S: Sequence>: View where S.Element == String {
    let docs: S
    let fullCount: Int
    @ObservedObject var monitor: SessionMonitor
    @ObservedObject var tabState: DocumentTabState
    @AppStorage("documentsCollapsed") private var documentsCollapsed: Bool = false

    var body: some View {
        let paths = Array(docs)
        VStack(alignment: .leading, spacing: 4) {
            DocumentsHeader(count: paths.count)
            ForEach(Array(paths.enumerated()), id: \.element) { index, path in
                documentCard(path: path, compact: index >= fullCount)
            }
        }
    }

    private func documentCard(path: String, compact: Bool = false) -> some View {
        let isImage = ViewableDocument.isImage(path)
        let isMarkdown = ViewableDocument.isMarkdown(path)
        let meta = (compact || isImage) ? nil : DocumentExcerptCache.excerpt(for: path)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: sidebarDocumentIcon(path))
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: .secondaryLabelColor))
                Text((path as NSString).lastPathComponent)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if !compact, isImage {
                imageThumbnail(path: path)
            }
            if let meta, !meta.title.isEmpty || !meta.excerpt.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    if !meta.title.isEmpty {
                        Text(meta.title)
                            .font(.system(size: 11))
                            .foregroundColor(Color(nsColor: .secondaryLabelColor))
                            .lineLimit(1)
                    }
                    if !meta.excerpt.isEmpty {
                        Text(meta.excerpt)
                            .font(.system(size: 11))
                            .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, compact ? 3 : 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(DocumentCardHoverModifier())
        .help(path)
        .onTapGesture {
            if isMarkdown || isImage {
                tabState.open(path: path)
                monitor.addDocument(path: path)
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        }
        .contextMenu {
            if isMarkdown || isImage {
                Button("Open in Tab") {
                    tabState.open(path: path)
                    monitor.addDocument(path: path)
                }
                Divider()
            }
            Button("Open in Default App") {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
            Button("Open With...") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    let panel = NSOpenPanel()
                    panel.message = "Choose an application"
                    panel.allowedContentTypes = [.application]
                    panel.directoryURL = URL(fileURLWithPath: "/Applications")
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let appURL = panel.url {
                        NSWorkspace.shared.open(
                            [URL(fileURLWithPath: path)],
                            withApplicationAt: appURL,
                            configuration: NSWorkspace.OpenConfiguration()
                        )
                    }
                }
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            Divider()
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
            Divider()
            Button("Remove from Sidebar") {
                if let openTab = tabState.tabs.first(where: { $0.path == path }) {
                    tabState.close(id: openTab.id)
                }
                monitor.removeDocument(path: path)
            }
        }
    }

    /// Loads the image off the main thread (NSImage(contentsOf:) is mostly
    /// header-only, but full decode for big PNGs can stall). Renders inside
    /// a fixed-height frame so doc cards don't jump as images load.
    @ViewBuilder
    private func imageThumbnail(path: String) -> some View {
        ImageThumbnail(path: path)
            .frame(maxWidth: .infinity)
            .frame(height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// Section header with a leading disclosure triangle. Clicking anywhere
/// on the header (triangle, label, or trailing count) toggles
/// `documentsCollapsed`, which is persisted via @AppStorage and applies
/// across all session windows. SidebarView renders this standalone when the
/// section is collapsed; DocumentsSection embeds it above its card list.
struct DocumentsHeader: View {
    let count: Int
    @AppStorage("documentsCollapsed") private var documentsCollapsed: Bool = false

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                documentsCollapsed.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color(nsColor: .secondaryLabelColor))
                    .rotationEffect(.degrees(documentsCollapsed ? 0 : 90))
                Text("DOCUMENTS")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(nsColor: .secondaryLabelColor))
                    .tracking(0.5)
                Spacer()
                if documentsCollapsed {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                }
            }
            .contentShape(Rectangle())
            .textSelection(.disabled)
        }
        .buttonStyle(.plain)
    }
}

struct DocumentCardHoverModifier: ViewModifier {
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            // Disable text selection on the clickable card — the sidebar's
            // root enables selection for prose, but on tap targets it
            // steals clicks (drag-to-select beats onTapGesture once started).
            .textSelection(.disabled)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: .quaternaryLabelColor)
                        .opacity(hovered ? 0.30 : 0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(nsColor: .separatorColor),
                            lineWidth: hovered ? 0.5 : 0)
            )
            .shadow(color: Color.black.opacity(hovered ? 0.18 : 0),
                    radius: hovered ? 4 : 0, x: 0, y: hovered ? 1 : 0)
            .contentShape(Rectangle())
            .onHover { isHovered in
                hovered = isHovered
                if isHovered {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}
