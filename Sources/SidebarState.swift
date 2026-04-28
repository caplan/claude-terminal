import Foundation

final class SidebarState: ObservableObject {
    @Published var isVisible: Bool
    @Published var width: CGFloat

    init(defaultVisible: Bool = true, width: CGFloat? = nil) {
        self.isVisible = defaultVisible
        self.width = width ?? CGFloat(UserDefaults.standard.double(forKey: "sidebarWidth").clamped(to: 220...500, default: 280))
    }

    func toggle() {
        isVisible.toggle()
    }

    func saveWidth() {
        UserDefaults.standard.set(Double(width), forKey: "sidebarWidth")
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>, default defaultValue: Double) -> Double {
        self == 0 ? defaultValue : min(max(self, range.lowerBound), range.upperBound)
    }
}
