import Foundation
import AppKit
import SwiftUI
import os.log
import Combine

public typealias PaneID = UUID
public typealias TabID = UUID

// MARK: - CtSurfaceConfigTemplate

struct CtSurfaceConfigTemplate {
    var fontSize: Float32 = 0
    var workingDirectory: String?
    var command: String?
    var environmentVariables: [String: String] = [:]
    var initialInput: String?
    var waitAfterCommand: Bool = false

    init() {}

    init(cConfig: ghostty_surface_config_s) {
        fontSize = cConfig.font_size
        if let workingDirectory = cConfig.working_directory {
            self.workingDirectory = String(cString: workingDirectory, encoding: .utf8)
        }
        if let command = cConfig.command {
            self.command = String(cString: command, encoding: .utf8)
        }
        if let initialInput = cConfig.initial_input {
            self.initialInput = String(cString: initialInput, encoding: .utf8)
        }
        if cConfig.env_var_count > 0, let envVars = cConfig.env_vars {
            for index in 0..<Int(cConfig.env_var_count) {
                let envVar = envVars[index]
                if let key = String(cString: envVar.key, encoding: .utf8),
                   let value = String(cString: envVar.value, encoding: .utf8) {
                    environmentVariables[key] = value
                }
            }
        }
        waitAfterCommand = cConfig.wait_after_command
    }
}

// MARK: - Environment

public enum DropZone: Equatable, Sendable {
    case center, left, right, top, bottom
}

private struct PaneDropZoneKey: EnvironmentKey {
    static let defaultValue: DropZone? = nil
}

extension EnvironmentValues {
    var paneDropZone: DropZone? {
        get { self[PaneDropZoneKey.self] }
        set { self[PaneDropZoneKey.self] = newValue }
    }
}

// MARK: - Logging

private let _dlogger = Logger(subsystem: "org.claire.claude-terminal", category: "debug")

func dlog(_ message: @autoclosure () -> String) {
    #if DEBUG
    let msg = message()
    _dlogger.debug("\(msg, privacy: .public)")
    #endif
}

// MARK: - Direction Enums

enum NavigationDirection {
    case up, down, left, right
}

public enum SplitOrientation: String, Sendable {
    case horizontal
    case vertical
}

enum SplitDirection {
    case left, right, up, down
    var isHorizontal: Bool { self == .left || self == .right }
    var orientation: SplitOrientation { isHorizontal ? .horizontal : .vertical }
    var insertFirst: Bool { self == .left || self == .up }
}

enum ResizeDirection {
    case left, right, up, down
    var splitOrientation: String { "" }
    var requiresPaneInFirstChild: Bool { false }
}

// MARK: - Notification / Flash

enum WorkspaceAttentionFlashReason: String, Equatable, Sendable {
    case navigation
    case notificationArrival
    case notificationDismiss
    case manualUnreadDismiss
    case debug
}

enum WorkspaceAttentionFlashAccent: Equatable, Sendable {
    case accentColor
    case custom(NSColor)

    var strokeColor: NSColor {
        switch self {
        case .accentColor: return .controlAccentColor
        case .custom(let color): return color
        }
    }
}

struct WorkspaceAttentionFlashPresentation: Equatable, Sendable {
    let accent: WorkspaceAttentionFlashAccent
    let glowOpacity: Double
    let glowRadius: CGFloat
}

enum PanelOverlayRingMetrics {
    static let inset: CGFloat = 2
    static let cornerRadius: CGFloat = 6
    static let lineWidth: CGFloat = 2.5

    static func pathRect(in bounds: CGRect) -> CGRect {
        bounds.insetBy(dx: inset, dy: inset)
    }
}

final class NotificationBurstCoalescer {
    init(delay: TimeInterval = 1.0 / 30.0) {}
    func signal(_ action: @escaping () -> Void) { action() }
}

// MARK: - Terminal Panel Focus

enum TerminalPanelFocusIntent: Equatable {
    case surface
    case findField
}

// MARK: - Image Transfer (stubs)

enum TerminalRemoteUploadTarget: Equatable {
    case scp(host: String, path: String)
}

enum TerminalImageTransferPlan: Equatable {
    case insertText(String)
    case uploadFiles([URL], TerminalRemoteUploadTarget)
    case reject
}

enum TerminalImageTransferPreparedContent: Equatable {
    case insertText(String)
    case fileURLs([URL])
    case reject
}

enum TerminalImageTransferTarget: Equatable {
    case local
    case remote(TerminalRemoteUploadTarget)
}

final class TerminalImageTransferOperation: @unchecked Sendable {
    var isCancelled: Bool { false }
    func installCancellationHandler(_ handler: @escaping () -> Void) {}
    func clearCancellationHandler() {}
    @discardableResult func cancel() -> Bool { false }
    @discardableResult func finish() -> Bool { false }
    func throwIfCancelled() throws {}
}

// MARK: - Search Overlay (stub)

struct SurfaceSearchOverlay: View {
    let tabId: UUID
    let surfaceId: UUID
    @ObservedObject var searchState: TerminalSurface.SearchState
    let canApplyFocusRequest: () -> Bool
    let onMoveFocusToTerminal: () -> Void
    let onNavigateSearch: (_ action: String) -> Void
    let onFieldDidFocus: () -> Void
    let onClose: () -> Void
    var body: some View { EmptyView() }
}

// MARK: - TerminalPanel (stub)

class TerminalPanel {
    var requestedWorkingDirectory: String? { nil }
}

// MARK: - TabManager (stub)

class TabManager: ObservableObject {
    weak var window: NSWindow?
    private var tabId: UUID?

    convenience init(window: NSWindow, tabId: UUID) {
        self.init()
        self.window = window
        self.tabId = tabId
    }

    var selectedTabId: UUID? { tabId }
    var tabs: [Workspace] {
        guard let tabId else { return [] }
        return [Workspace(id: tabId)]
    }
    func debugCurrentWorkspaceSwitchSnapshot() -> WorkspaceSwitchSnapshot? { nil }
    @discardableResult func moveSplitFocus(direction: NavigationDirection, inWorkspace: Workspace? = nil, inPane: PaneID? = nil) -> Bool { false }
    @discardableResult func moveSplitFocus(tabId: UUID, surfaceId: UUID, direction: NavigationDirection) -> Bool { false }
    @discardableResult func resizeSplit(direction: ResizeDirection, amount: UInt16, inWorkspace: Workspace? = nil) -> Bool { false }
    @discardableResult func resizeSplit(tabId: UUID, surfaceId: UUID, direction: ResizeDirection, amount: UInt16) -> Bool { false }
    func createSplit(direction: SplitDirection, inWorkspace: Workspace? = nil) {}
    @discardableResult func createSplit(tabId: UUID, surfaceId: UUID, direction: SplitDirection) -> UUID? { nil }
    @discardableResult func equalizeSplits(tabId: UUID) -> Bool { false }
    @discardableResult func toggleSplitZoom(tabId: UUID, surfaceId: UUID) -> Bool { false }
    func updateSurfaceDirectory(tabId: UUID, surfaceId: UUID, directory: String) {}
    func titleForTab(_ tabId: UUID) -> String? { nil }
    func closeRuntimeSurfaceWithConfirmation(tabId: UUID, surfaceId: UUID) {}
    func closeRuntimeSurface(tabId: UUID, surfaceId: UUID) {}
    func closePanelAfterChildExited(tabId: UUID, surfaceId: UUID) {
        window?.close()
    }
    func dismissNotificationOnDirectInteraction(tabId: UUID, surfaceId: UUID) {}
    func focusedSurfaceId(for tabId: UUID) -> UUID? { nil }
}

// MARK: - WorkspaceSwitchSnapshot

struct WorkspaceSwitchSnapshot {
    let startedAt: CFTimeInterval
    let id: UUID
}

// MARK: - Workspace Panel Dictionary

struct WorkspacePanelDictionary {
    private let returnStub: Bool
    init(returnStub: Bool = false) { self.returnStub = returnStub }
    subscript(_ id: UUID?) -> TerminalPanel? { returnStub ? TerminalPanel() : nil }
    subscript(_ id: UUID) -> TerminalPanel? { returnStub ? TerminalPanel() : nil }
}

// MARK: - Workspace Panel Directories Dictionary

struct WorkspacePanelDirectories {
    subscript(_ id: UUID) -> String? { nil }
}

// MARK: - WorkspaceContainingPanelResult

struct WorkspaceContainingPanelResult {
    let workspace: Workspace
}

// MARK: - Workspace (stub)

@MainActor
final class Workspace: Identifiable, ObservableObject {
    let id: UUID
    let bonsplitController: BonsplitController
    static let terminalScrollBarHiddenDidChangeNotification = Notification.Name("claudeTerminal.scrollBarHiddenDidChange")
    var terminalScrollBarHidden: Bool = false
    var currentDirectory: String { "" }
    var panelDirectories: WorkspacePanelDirectories { WorkspacePanelDirectories() }
    var panels: WorkspacePanelDictionary { WorkspacePanelDictionary(returnStub: true) }

    nonisolated init(id: UUID = UUID()) {
        self.id = id
        self.bonsplitController = BonsplitController()
    }
    var agentPIDs: [String: Any] { [:] }
    var focusedPanelId: UUID? { nil }
    func isRemoteTerminalSurface(_ surface: TerminalSurface) -> Bool { false }
    func isRemoteTerminalSurface(_ surfaceId: UUID) -> Bool { false }
    var terminalPanel: Any? { nil }
    func terminalPanel(for surfaceId: UUID) -> TerminalPanel? { nil }
    func openOrFocusMarkdownSplit(url: URL, title: String?) {}
    @discardableResult func openOrFocusMarkdownSplit(from surfaceId: UUID, filePath: String) -> UUID? { nil }
    func surfaceIdFromPanelId(_ panelId: UUID) -> UUID? { bonsplitController.stubTabId }
    func preferredBrowserTargetPane(fromPanelId panelId: UUID) -> UUID? { nil }
    @discardableResult func newBrowserSurface(inPane paneId: UUID, url: URL, focus: Bool) -> UUID? { nil }
    @discardableResult func newBrowserSplit(from panelId: UUID, orientation: SplitOrientation, url: URL) -> UUID? { nil }
    func uploadDroppedFilesForRemoteTerminal(
        _ fileURLs: [URL],
        operation: TerminalImageTransferOperation,
        completion: @escaping (Result<String, Error>) -> Void
    ) {}
}

@MainActor
final class BonsplitController {
    let stubTabId: TabID
    private let paneId: PaneID
    nonisolated init() {
        self.stubTabId = TabID()
        self.paneId = PaneID()
    }
    var allPaneIds: [PaneID] { [paneId] }
    var focusedPaneId: PaneID? { paneId }
    func tabs(inPane paneId: PaneID) -> [BonsplitTab] { [BonsplitTab(id: stubTabId)] }
    func selectedTab(inPane paneId: PaneID) -> BonsplitTab? { BonsplitTab(id: stubTabId) }
}

struct BonsplitTab: Identifiable {
    let id: TabID
    var title: String = ""
}

// MARK: - Telemetry (stub)

enum TelemetrySettings {
    static let sendAnonymousTelemetryKey = "sendAnonymousTelemetry"
    static let defaultSendAnonymousTelemetry = false
    static let enabledForCurrentLaunch: Bool = false

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool { false }
}

// MARK: - SocketControlSettings (stub)

enum SocketControlSettings {
    static func isDebugLikeBundleIdentifier(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier.hasSuffix(".debug") || bundleIdentifier.contains(".debug.")
    }
    static func socketPath(bundleIdentifier: String? = nil, currentUserID: uid_t? = nil) -> String {
        "/tmp/claude-terminal.sock"
    }
}

// MARK: - Settings Stubs

enum BrowserInsecureHTTPSettings {
    static let allowInsecureHTTPKey = "browserAllowInsecureHTTP"
    static let defaultValue = false

    static func normalizeHost(_ host: String) -> String? { host.isEmpty ? nil : host }
}

enum BrowserLinkOpenSettings {
    static let openLinksInBrowserKey = "openLinksInBrowser"
    static let defaultValue = false

    static func openTerminalLinksInCtBrowser() -> Bool { false }
    static func shouldOpenExternally(_ url: URL) -> Bool { false }
    static func hostMatchesWhitelist(_ host: String) -> Bool { true }
}

enum ClaudeCodeIntegrationSettings {
    static let enabledKey = "claudeCodeIntegration"
    static let defaultEnabled = false

    static func hooksEnabled() -> Bool { defaultEnabled }
    static func customClaudePath() -> String? { nil }
}

enum CmdClickMarkdownRouteSettings {
    static let enabledKey = "cmdClickMarkdownRoute"
    static let defaultEnabled = false

    static func isEnabled() -> Bool { defaultEnabled }
    static func isMarkdownPath(_ path: String) -> Bool { false }
    static func shouldRoute(path: String) -> Bool { false }
}

enum CursorIntegrationSettings {
    static let enabledKey = "cursorIntegration"
    static let defaultEnabled = false

    static func hooksEnabled() -> Bool { defaultEnabled }
}

enum GeminiIntegrationSettings {
    static let enabledKey = "geminiIntegration"
    static let defaultEnabled = false

    static func hooksEnabled() -> Bool { defaultEnabled }
}

enum PaneFirstClickFocusSettings {
    static let enabledKey = "paneFirstClickFocus"
    static let defaultEnabled = true

    static func isEnabled() -> Bool { defaultEnabled }
}

enum PreferredEditorSettings {
    static let editorKey = "preferredEditor"
    static let defaultEditor = ""

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

enum TerminalScrollBarSettings {
    static let hiddenKey = "terminalScrollBarHidden"
    static let defaultHidden = false
    static let didChangeNotification = Notification.Name("claudeTerminal.terminalScrollBarSettingsDidChange")
    static func isVisible() -> Bool { true }
}

enum FocusFlashPattern {
    enum Curve {
        case easeIn
        case easeOut
    }
    static let values: [Double] = [0, 0.6, 0]
    static let keyTimes: [Double] = [0, 0.3, 1.0]
    static let duration: TimeInterval = 0.5
    static let curves: [Curve] = [.easeIn, .easeOut]
}

struct KeyboardLayout {
    static let current = KeyboardLayout()
    static var id: String? { nil }
    static func character(forKeyCode keyCode: UInt16) -> String? { nil }
    func isNonLatin() -> Bool { false }
}

enum KeyboardShortcutSettings {
    static let customShortcuts: [String: String] = [:]
    static var settingsFileStore = SettingsFileStore()

    struct SettingsFileStore {
        func reload() {}
    }
}

class FocusLogStore {
    static let shared = FocusLogStore()
    func log(_ message: String) {}
    func append(_ message: String) {}
}

class SessionScrollbackReplayStore {
    static let shared = SessionScrollbackReplayStore()
    static let environmentKey: String = "CT_SESSION_SCROLLBACK_REPLAY"
}

class TerminalController {
    static let shared = TerminalController()
    func readTerminalTextForSnapshot(terminalPanel: TerminalPanel, lineLimit: Int) -> String? { nil }
}

class TerminalNotificationStore: ObservableObject {
    static let shared = TerminalNotificationStore()
    func handle(notification: Any) {}
    func addNotification(tabId: UUID, surfaceId: UUID?, title: String, subtitle: String, body: String) {}
}

enum TerminalImageTransferPlanner {
    enum Mode {
        case paste
        case drop
    }
    static func prepare(pasteboard: NSPasteboard, mode: Mode) -> TerminalImageTransferPreparedContent {
        if let text = GhosttyPasteboardHelper.stringContents(from: pasteboard) {
            return .insertText(text)
        }
        return .reject
    }
    static func plan(fileURLs: [URL], target: TerminalImageTransferTarget) -> TerminalImageTransferPlan {
        .reject
    }
    static func plan(pasteboard: NSPasteboard, mode: Mode, target: TerminalImageTransferTarget) -> TerminalImageTransferPlan {
        .reject
    }
    static func escapeForShell(_ value: String) -> String { value }
    static func execute(
        plan: TerminalImageTransferPlan,
        operation: TerminalImageTransferOperation,
        uploadWorkspaceRemote: @escaping ([URL], TerminalImageTransferOperation, @escaping (Result<String, Error>) -> Void) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {}
    static func execute(
        plan: TerminalImageTransferPlan,
        operation: TerminalImageTransferOperation? = nil,
        uploadWorkspaceRemote: @escaping ([URL], TerminalImageTransferOperation, @escaping (Result<String, Error>) -> Void) -> Void,
        insertText: @escaping (String) -> Void,
        onFailure: @escaping (Error?) -> Void
    ) {}
    static func execute(
        plan: TerminalImageTransferPlan,
        uploadWorkspaceRemote: ([URL], TerminalImageTransferOperation, @escaping (Result<[String], Error>) -> Void) -> Void,
        insertText: @escaping (String) -> Void,
        onFailure: @escaping (Error?) -> Void
    ) {}
}

class WorkspaceAttentionCoordinator {
    init() {}
    func flash(reason: WorkspaceAttentionFlashReason) {}

    static func flashStyle(for reason: WorkspaceAttentionFlashReason) -> WorkspaceAttentionFlashPresentation {
        WorkspaceAttentionFlashPresentation(
            accent: .accentColor,
            glowOpacity: 0.5,
            glowRadius: 8
        )
    }
}

struct WindowGlassEffect: ViewModifier {
    static var isAvailable: Bool { false }
    func body(content: Content) -> some View { content }
}

struct CtRuntimeDebugCapture {
    static let shared: CtRuntimeDebugCapture? = nil
    func capture(_ message: String) {}

    static func logIfConfigured(
        hypothesisID: String,
        source: String,
        name: String,
        expected: String? = nil,
        actual: String? = nil,
        data: [String: Any] = [:]
    ) {}
}

struct CtUITestCapture {
    static let shared: CtUITestCapture? = nil

    @discardableResult
    static func mutateJSONObjectIfConfigured(
        envKey: String,
        _ mutator: (inout [String: Any]) -> Void
    ) -> Bool {
        false
    }
}

enum CtTypingTiming {
    static func markKeyDown() {}
    static func markSurfaceWrite() {}
    static func markSurfaceRender() {}
    static func start() -> Date { Date() }
    static func logDuration(path: String, startedAt: Date, extra: String = "") {}
    static func logDuration(path: String, startedAt: Date, event: NSEvent?, extra: String = "") {}
    static func logEventDelay(path: String, event: NSEvent) {}
    static func logBreakdown(
        path: String,
        totalMs: Double,
        event: NSEvent,
        thresholdMs: Double = 1.0,
        parts: [(String, Double)],
        extra: String = ""
    ) {}
}

// MARK: - Free functions (stubs)

func ctAccentNSColor() -> NSColor { .controlAccentColor }

func ctCurrentSurfaceFontSizePoints() -> CGFloat { 13 }

func ctCurrentSurfaceFontSizePoints(_ surface: ghostty_surface_t) -> Float32? { 13 }

func ctSurfacePointerAppearsLive(_ pointer: UnsafeMutableRawPointer?) -> Bool {
    guard let pointer, malloc_zone_from_ptr(pointer) != nil else { return false }
    return malloc_size(pointer) > 0
}

func resolveBrowserNavigableURL(_ url: URL) -> URL? { url }
func resolveBrowserNavigableURL(_ string: String) -> URL? {
    URL(string: string.hasPrefix("http") ? string : "https://\(string)")
}

// MARK: - NSColor Extensions

extension NSColor {
    func hexString(includeAlpha: Bool = false) -> String {
        let color = usingColorSpace(.sRGB) ?? self
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let redByte = min(255, max(0, Int(red * 255)))
        let greenByte = min(255, max(0, Int(green * 255)))
        let blueByte = min(255, max(0, Int(blue * 255)))
        if includeAlpha {
            let alphaByte = min(255, max(0, Int(alpha * 255)))
            return String(format: "#%02X%02X%02X%02X", redByte, greenByte, blueByte, alphaByte)
        }
        return String(format: "#%02X%02X%02X", redByte, greenByte, blueByte)
    }
}

// MARK: - NSNotification.Name Extensions

extension NSNotification.Name {
    static let terminalPortalVisibilityDidChange = NSNotification.Name("claudeTerminal.portalVisibilityDidChange")
    static let ghosttyDidSetTitle = NSNotification.Name("claudeTerminal.ghosttyDidSetTitle")
    static let terminalSurfaceDidBecomeReady = NSNotification.Name("claudeTerminal.surfaceDidBecomeReady")
    static let terminalSurfaceHostedViewDidMoveToWindow = NSNotification.Name("claudeTerminal.hostedViewDidMoveToWindow")
    static let ghosttyDidBecomeFirstResponderSurface = NSNotification.Name("claudeTerminal.didBecomeFirstResponderSurface")
}

// MARK: - TerminalWindowPortalRegistry (stub)

enum TerminalWindowPortalRegistry {
    struct Entry {
        let startedAt: Date = Date()
        let id: UUID = UUID()
    }

    private static var bindings: [ObjectIdentifier: ObjectIdentifier] = [:]

    static func bind(hostedView: NSView, to host: NSView, visibleInUI: Bool, zPriority: Int, expectedSurfaceId: UUID, expectedGeneration: UInt64) {
        if hostedView.superview !== host {
            hostedView.removeFromSuperview()
            host.addSubview(hostedView)
            hostedView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                hostedView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                hostedView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                hostedView.topAnchor.constraint(equalTo: host.topAnchor),
                hostedView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
        }
        hostedView.isHidden = !visibleInUI
        bindings[ObjectIdentifier(hostedView)] = ObjectIdentifier(host)
    }

    static func unbind(hostedView: NSView) {
        hostedView.removeFromSuperview()
        bindings.removeValue(forKey: ObjectIdentifier(hostedView))
    }

    static var isInteractiveGeometryResizeActive: Bool { false }
    static func synchronizeForAnchor(_ view: NSView, forceSync: Bool = false) {}
    static func scheduleExternalGeometrySynchronize() {}
    static func scheduleExternalGeometrySynchronize(for window: NSWindow) {}

    static func isHostedView(_ view: NSView, boundTo host: NSView) -> Bool {
        bindings[ObjectIdentifier(view)] == ObjectIdentifier(host)
    }

    static func updateEntryVisibility(for hostedView: NSView, visibleInUI: Bool) {
        hostedView.isHidden = !visibleInUI
    }
}

// MARK: - UUID Extension

extension UUID {
    var id: UUID { self }
}

// MARK: - TerminalRemoteUploadTarget Extension

extension TerminalRemoteUploadTarget {
    static func workspaceRemote(for workspace: Workspace?) -> TerminalRemoteUploadTarget? { nil }
    /// Convenience for test helpers that don't have a workspace reference.
    static var workspaceRemote: TerminalRemoteUploadTarget { .scp(host: "", path: "") }
}

// MARK: - TerminalSurface Extension (stubs)

extension TerminalSurface {
    func resolvedImageTransferTarget() -> TerminalImageTransferTarget { .local }
}

// MARK: - Surface Context Helper

func ctSurfaceContextName(_ context: ghostty_surface_context_e) -> String {
    switch context {
    case GHOSTTY_SURFACE_CONTEXT_WINDOW:
        return "window"
    case GHOSTTY_SURFACE_CONTEXT_TAB:
        return "tab"
    case GHOSTTY_SURFACE_CONTEXT_SPLIT:
        return "split"
    default:
        return "unknown(\(context))"
    }
}
