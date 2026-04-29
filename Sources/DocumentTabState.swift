import Foundation

struct DocumentTab: Identifiable, Equatable {
    let id: UUID
    var path: String
    var title: String
}

final class DocumentTabState: ObservableObject {
    @Published var tabs: [DocumentTab] = []
    @Published var active: UUID? = nil

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
        }
    }

    func activate(_ id: UUID?) {
        active = id
    }
}
