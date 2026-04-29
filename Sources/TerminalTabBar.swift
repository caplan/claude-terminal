import SwiftUI

struct TerminalTabBar: View {
    @ObservedObject var state: DocumentTabState

    var body: some View {
        HStack(spacing: 4) {
            TabChip(
                label: "Terminal",
                systemImage: "terminal",
                isActive: state.active == nil,
                closable: false,
                onClick: { state.activate(nil) },
                onClose: {}
            )
            ForEach(state.tabs) { tab in
                TabChip(
                    label: tab.title,
                    systemImage: "doc.text",
                    isActive: state.active == tab.id,
                    closable: true,
                    onClick: { state.activate(tab.id) },
                    onClose: { state.close(id: tab.id) }
                )
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(height: 30)
        .background(
            VisualEffectBackground(material: .titlebar)
        )
        .overlay(
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1),
            alignment: .bottom
        )
    }
}

private struct TabChip: View {
    let label: String
    let systemImage: String
    let isActive: Bool
    let closable: Bool
    let onClick: () -> Void
    let onClose: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(isActive ? .primary : Color(nsColor: .secondaryLabelColor))
            Text(label)
                .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                .foregroundColor(isActive ? .primary : Color(nsColor: .secondaryLabelColor))
                .lineLimit(1)
                .truncationMode(.middle)
            if closable {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                        .padding(2)
                        .background(
                            Circle()
                                .fill(hovering ? Color(nsColor: .quaternaryLabelColor) : .clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: 220)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color(nsColor: .controlBackgroundColor) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isActive ? Color(nsColor: .separatorColor) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onClick() }
    }
}

