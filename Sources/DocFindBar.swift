import SwiftUI

struct DocFindBar: View {
    @ObservedObject var tabState: DocumentTabState
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(nsColor: .secondaryLabelColor))
            TextField("Find", text: $tabState.findQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .frame(width: 220)
                .focused($focused)
                .onSubmit {
                    tabState.findNext(backwards: NSEvent.modifierFlags.contains(.shift))
                }
                .onChange(of: tabState.findQuery) { q in
                    if !q.isEmpty { tabState.find(q) }
                }
            Button { tabState.findNext(backwards: true) } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(tabState.findQuery.isEmpty)
            Button { tabState.findNext(backwards: false) } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(tabState.findQuery.isEmpty)
            Button { tabState.findActive = false } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.95))
                .shadow(color: Color.black.opacity(0.18), radius: 6, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .onAppear {
            // SwiftUI's @FocusState doesn't reliably take over first-responder
            // status when the bar is overlaid on top of a WKWebView — defer a
            // tick so the text field has a chance to mount.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                focused = true
            }
        }
    }
}
