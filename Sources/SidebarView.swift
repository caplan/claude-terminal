import SwiftUI
import UniformTypeIdentifiers

private extension Color {
    init(hex: UInt32) {
        self.init(
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >>  8) & 0xFF) / 255,
            blue:  Double( hex        & 0xFF) / 255
        )
    }
}

struct SidebarView: View {
    @ObservedObject var monitor: SessionMonitor
    @ObservedObject var tabState: DocumentTabState
    var width: CGFloat = 280

    @State private var isDropTargeted = false
    @ObservedObject private var githubStatus = GitHubStatusMonitor.shared
    /// Timestamp of the most recent idle transition. Used to keep the
    /// assistant headline visible for ~10 seconds after the session quiets
    /// down, so the user can glance up from the terminal and still see what
    /// Claude last said.
    @State private var idleAt: Date?
    /// Per-second snapshots of session activity, powering the bidirectional
    /// activity bar chart in the Where Time Went section. Each sample reflects
    /// the fraction of the second spent in each bucket (0..1) plus how long
    /// the bucket has been continuously busy at sample time — the streak
    /// drives a blue → yellow → orange → red → dark-red color ramp so a
    /// stuck call jumps out visually.
    @State private var activitySamples: [ActivitySample] = []
    /// 100ms sub-samples accumulated into the next emitted activitySample.
    @State private var subSampleClaude: Int = 0
    @State private var subSampleTool: Int = 0
    @State private var subSampleCount: Int = 0
    /// Continuous-busy duration (seconds) for each bucket. Reset to 0 the
    /// instant the bucket goes idle.
    @State private var claudeStreakSecs: Double = 0
    @State private var toolStreakSecs: Double = 0
    /// Wall-clock time of the most recent emitted sample. The chart's
    /// TimelineView animation interpolates between samples by reading
    /// `Date().timeIntervalSince(lastSampleTime)` and scaling it to a
    /// horizontal slide of one bar-width per second.
    @State private var lastSampleTime: Date = Date()
    /// Diagnostic state for the activity logger — only writes a line on
    /// status / claudeBusy / toolBusy transitions, not every tick.
    @State private var loggedClaudeBusy: Bool? = nil
    @State private var loggedToolBusy: Bool? = nil
    @State private var loggedStatusRaw: String? = nil
    /// Last observed cumulative tool-ms — used to detect short-lived tools
    /// (Read/Edit/etc.) that complete between two 10Hz ticks.
    @State private var lastObservedToolMsTotal: Int = 0
    /// Set of tool IDs that were active on the previous tick. Any new ID
    /// this tick means a fresh tool started, so the tool hue ramp resets.
    @State private var prevActiveToolIds: Set<String> = []
    /// True if a new tool began during the current 3s window — the emitted
    /// sample inherits this flag and the chart adds a small left inset to
    /// the tool rectangle, visually separating it from the prior tool run.
    @State private var toolStartedThisWindow: Bool = false
    /// Distinct tool names seen during the current 3s window, in first-
    /// observed order. Rendered as a hover tooltip on the tool bar so
    /// users can see which tools produced the activity.
    @State private var toolNamesThisWindow: [String] = []
    private static let activityWindow = 60
    private static let subSampleHz: Double = 10
    private static let barDurationSecs: Double = 3
    private static let subSamplesPerSample = Int(subSampleHz * barDurationSecs)

    private struct ActivitySample: Equatable {
        let claude: Double          // 0..1 fraction of second
        let tool: Double            // 0..1 fraction of second
        let claudeStreakSecs: Double
        let toolStreakSecs: Double
        // True if a new tool started during this window — the renderer
        // adds a left inset so the bar visually detaches from the prior
        // tool's run of bars.
        let toolIsNewToolStart: Bool
        // Distinct tool names observed during this window, in first-seen
        // order. Surfaced as the hover tooltip on the tool bar.
        let toolNames: [String]
    }
    /// User toggle for the Documents section. Defaults to expanded; persisted
    /// in UserDefaults so it survives relaunches and is shared across windows
    /// (one global preference, not per-session — matches sidebar visibility).
    @AppStorage("documentsCollapsed") private var documentsCollapsed: Bool = false

    private var state: SessionState { monitor.state }

    var body: some View {
        GeometryReader { geo in
            let collapse = collapseLevel(availableHeight: geo.size.height - 32)
            VStack(alignment: .leading, spacing: 12) {
                headerSection
                sectionCard { statusSection }

                if !state.subagents.isEmpty {
                    sectionCard { subagentsSection }
                }
                if state.tasks.contains(where: { $0.status != "completed" }) {
                    sectionCard { tasksSection }
                }
                // state.documents is pre-filtered for file existence in
                // SessionMonitor.readAndDecode; trust it here to avoid stat
                // syscalls on every SwiftUI redraw.
                if let docs = state.documents, !docs.isEmpty {
                    if documentsCollapsed {
                        // Collapsed: just the header card with the disclosure
                        // triangle + count. Doesn't expand to fill height, so
                        // the bottom sections move up.
                        sectionCard { documentsHeader(count: docs.count) }
                        Spacer(minLength: 0)
                    } else {
                        let fullCount = fullSizeDocCount(
                            docsCount: docs.count,
                            availableHeight: geo.size.height - 32,
                            collapse: collapse
                        )
                        ScrollView(.vertical, showsIndicators: false) {
                            sectionCard { documentsSection(docs.reversed(), fullCount: fullCount) }
                        }
                        .frame(maxHeight: .infinity)
                    }
                } else {
                    Spacer(minLength: 0)
                }

                sectionCard { activitySection() }
                if let context = state.contextUsage {
                    sectionCard {
                        if collapse >= 3 {
                            collapsedContextSection(context)
                        } else {
                            contextSection(context)
                        }
                    }
                }
                if let cost = state.cost {
                    sectionCard {
                        if collapse >= 2 {
                            collapsedCostSection(cost)
                        } else {
                            costSection(cost)
                        }
                    }
                }
            }
            .padding(16)
            .frame(width: width)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .background(VisualEffectBackground(material: .sidebar))
        .onReceive(Timer.publish(every: 1.0 / Self.subSampleHz, on: .main, in: .common).autoconnect()) { _ in
            tickActivitySubSample()
        }
        // Cascades to every Text inside the sidebar so prose, paths, costs,
        // assistant headlines, etc. can be selected and copied. Buttons /
        // tappable cards still take precedence for click handling because
        // text selection only kicks in on drag.
        .textSelection(.enabled)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor, lineWidth: 2)
                .padding(4)
                .opacity(isDropTargeted ? 1 : 0)
                .allowsHitTesting(false)
        )
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDropProviders(providers)
        }
        .onChange(of: state.status) { newStatus in
            if newStatus == .idle {
                let now = Date()
                idleAt = now
                // Fire-and-forget: clear the idle timestamp 10s later so the
                // headline disappears. The snapshot guard keeps a stale timer
                // from clobbering a fresher idle (e.g. user reactivates within
                // the window and then goes idle again).
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(10))
                    if idleAt == now { idleAt = nil }
                }
            } else {
                idleAt = nil
            }
        }
    }

    private func handleDropProviders(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                let path = url.path
                guard ViewableDocument.isViewable(path) else { return }
                DispatchQueue.main.async {
                    self.tabState.open(path: path)
                    self.monitor.addDocument(path: path)
                }
            }
        }
        return accepted
    }

    /// Returns how many of the top-most doc cards should be shown in their
    /// full-size form (name + title + 2-line excerpt). The remainder, at the
    /// bottom of the list, render in the compact single-line form. If even
    /// all-compact overflows the viewport the ScrollView still takes over.
    private func fullSizeDocCount(docsCount: Int, availableHeight: CGFloat, collapse: Int) -> Int {
        // Fixed height above the docs area (padding + header + status + any
        // subagents/tasks cards). Mirrors the constants in collapseLevel.
        var aboveDocs: CGFloat = 90 + 12 + 94
        if !state.subagents.isEmpty {
            aboveDocs += 12 + CGFloat(32 + state.subagents.count * 52) + 24
        }
        if state.tasks.contains(where: { $0.status != "completed" }) {
            aboveDocs += 12 + CGFloat(32 + state.tasks.count * 32) + 24
        }

        // Fixed height below the docs area at the current collapse level.
        let netH: CGFloat = 12 + 80
        let ctxH: CGFloat = state.contextUsage != nil ? 12 + (collapse >= 3 ? 44 : 144) : 0
        let costH: CGFloat = state.cost != nil ? 12 + (collapse >= 2 ? 44 : 124) : 0
        let belowDocs = netH + ctxH + costH

        // Section header + sectionCard padding adds ~56pt. Full doc card
        // (with excerpt) is ~78pt including spacing; compact card is ~28pt.
        let chromeH: CGFloat = 56
        let fullH: CGFloat = 78
        let compactH: CGFloat = 28
        let budget = max(0, availableHeight - aboveDocs - belowDocs - chromeH)

        if CGFloat(docsCount) * fullH <= budget { return docsCount }
        // Solve: full * fullH + (docsCount - full) * compactH <= budget
        let allCompact = CGFloat(docsCount) * compactH
        let slack = budget - allCompact
        if slack <= 0 { return 0 }
        let full = Int(floor(slack / (fullH - compactH)))
        return max(0, min(docsCount, full))
    }

    private func collapseLevel(availableHeight: CGFloat) -> Int {
        var fixed: CGFloat = 90 + 12 + 94
        if !state.subagents.isEmpty {
            fixed += 12 + CGFloat(32 + state.subagents.count * 52) + 24
        }
        if state.tasks.contains(where: { $0.status != "completed" }) {
            fixed += 12 + CGFloat(32 + state.tasks.count * 32) + 24
        }
        // Reserve a minimum viewport for the scrolling Documents area so it
        // stays visible even when many docs are present. Cost / context /
        // network sections always fit at the bottom.
        let hasDocs = state.documents?.isEmpty == false
        if hasDocs {
            fixed += 12 + 32 + 24 + 62
        }

        let netFull: CGFloat = 12 + 80
        let netSmall: CGFloat = 12 + 80
        let costFull: CGFloat = state.cost != nil ? 12 + 124 : 0
        let costSmall: CGFloat = state.cost != nil ? 12 + 44 : 0
        let ctxFull: CGFloat = state.contextUsage != nil ? 12 + 144 : 0
        let ctxSmall: CGFloat = state.contextUsage != nil ? 12 + 44 : 0

        if fixed + netFull + ctxFull + costFull <= availableHeight { return 0 }
        if fixed + netSmall + ctxFull + costFull <= availableHeight { return 1 }
        if fixed + netSmall + ctxFull + costSmall <= availableHeight { return 2 }
        return 3
    }

    private func sectionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
            )
    }

    // MARK: - Sections

    private var displayName: String {
        if let name = state.sessionName, !name.isEmpty { return name }
        return "Session"
    }

    /// Renders a small warning icon next to the working-directory line when
    /// (a) the session cwd is inside a git repo and (b) GitHub's status
    /// indicator is anything other than `none` / `unknown`. Clicking opens
    /// status.github.com in the browser; hovering shows the incident
    /// summary returned by the status API.
    @ViewBuilder
    private func githubStatusBadge(dir: String) -> some View {
        let indicator = githubStatus.indicator
        if indicator != .none, indicator != .unknown,
           GitRepoDetector.isInGitRepo(dir) {
            let tooltip = githubStatus.summary.isEmpty
                ? "GitHub Status"
                : "GitHub: \(githubStatus.summary)"
            Button {
                NSWorkspace.shared.open(URL(string: "https://status.github.com")!)
            } label: {
                Image("github")
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 20, height: 20)
                    .foregroundColor(githubStatusColor(indicator))
            }
            .buttonStyle(.plain)
            .modifier(InstantTooltip(text: tooltip))
        }
    }

    private func githubStatusColor(_ indicator: GitHubStatusMonitor.Indicator) -> Color {
        switch indicator {
        case .minor:       return .yellow
        case .major:       return .orange
        case .critical:    return .red
        case .maintenance: return .blue
        case .none, .unknown:
            return .primary
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let favicon = FaviconLoader.favicon(for: state.workingDirectory, size: 20) {
                    Image(nsImage: favicon)
                        .frame(width: 20, height: 20)
                }
                Text(displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
                Image(systemName: "pencil")
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    .onTapGesture {
                        NotificationCenter.default.post(name: .renameSession, object: nil)
                    }
            }
            if let dir = state.workingDirectory {
                HStack(spacing: 4) {
                    githubStatusBadge(dir: dir)
                    Text(abbreviatePath(dir))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let dir = state.workingDirectory,
               let ticket = JiraTicketDetector.ticket(for: dir) {
                Link(destination: ticket.url) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ticket.key)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                        if let title = ticket.title {
                            Text(title)
                                .font(.system(size: 12))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .foregroundColor(.blue)
                }
            }
            if let model = state.modelName {
                HStack(spacing: 6) {
                    Text(model)
                        .font(.system(size: 13))
                        .foregroundColor(Color(nsColor: .secondaryLabelColor))
                    // PLAN/YOLO badge is currently disabled because Claude Code
                    // only surfaces permission_mode in hook event payloads (not
                    // on Shift+Tab while idle and not in the statusline JSON).
                    // That meant the badge stayed stale until the user's next
                    // prompt, which is worse than showing nothing. The capture
                    // pipeline (SessionState.permissionMode, the hook/statusline
                    // writers, and permissionBadge below) is left in place so
                    // we can re-enable by removing `&& false` if Claude Code
                    // ever starts emitting mode changes via hook or statusline.
                    if let badge = permissionBadge(state.permissionMode), false {
                        Text(badge.label)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(badge.color)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(badge.color, lineWidth: 1)
                            )
                    }
                }
            }
            if let turns = state.conversationTurns {
                Text("\(turns) turns")
                    .font(.system(size: 12))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
            }
        }
    }

    @ViewBuilder
    private func toolCard(tool: String, detail: String?) -> some View {
        let color = toolColor(tool)
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if let detail, !detail.isEmpty {
                    ToolDetailText(
                        label: toolDetailLabel(tool, detail: detail),
                        rawDetail: detail,
                        color: color
                    )
                } else {
                    Text(toolVerb(tool).capitalized)
                        .font(.system(size: 12))
                        .foregroundColor(color)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !["Bash", "Read", "Edit"].contains(tool) {
                Text(tool)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            statusHeader
            pulseRow
            if let headline = shortAssistantHeadline {
                assistantHeadlineCard(text: headline)
            }
            if let active = state.activeTools, active.count > 1 {
                ForEach(active) { entry in
                    toolCard(tool: entry.tool, detail: entry.detail)
                }
            } else if let tool = state.currentToolName {
                toolCard(tool: tool, detail: state.toolDetail)
            }
        }
    }

    /// Layer 1: state dot + word, plus a right-aligned chip ribbon that only
    /// surfaces non-zero signal (errors so far, queued tasks above the count
    /// of active ones, plan/yolo).
    private var pulseRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor(state.status))
                .frame(width: 8, height: 8)
            Text(statusLabel(state.status))
                .font(.system(size: 14))
                .foregroundColor(.primary)
            Spacer(minLength: 8)
            chipRibbon
        }
    }

    @ViewBuilder
    private var chipRibbon: some View {
        HStack(spacing: 4) {
            if monitor.transcript.currentTurnErrorCount > 0 {
                statusChip(
                    label: "⚠ \(monitor.transcript.currentTurnErrorCount)",
                    color: .red
                )
            }
            // Plan/YOLO badge stays gated on the same flag as before
            // (Claude Code only reports permission_mode at hook events,
            // so the badge would lag behind Shift+Tab toggles).
            if let badge = permissionBadge(state.permissionMode), false {
                statusChip(label: badge.label, color: badge.color)
            }
        }
    }

    private func statusChip(label: String, color: Color) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15))
            .cornerRadius(3)
    }

    private var shortAssistantHeadline: String? {
        let isActive = state.status != .idle && state.status != .disconnected
        let withinIdleGrace = !isActive
            && (idleAt.map { Date().timeIntervalSince($0) < 10 } ?? false)
        guard isActive || withinIdleGrace else { return nil }
        guard var text = monitor.latestAssistantText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        while text.hasSuffix(":") { text.removeLast() }
        return text.isEmpty ? nil : text
    }

    @ViewBuilder
    private func assistantHeadlineCard(text: String) -> some View {
        renderInlineMarkdown(text)
            .font(.system(size: 12, weight: .regular))
            .foregroundColor(Color(nsColor: .secondaryLabelColor))
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    /// Parses inline markdown so `**bold**` and `*italic*` render with the
    /// expected styling and `` `code` ``/links collapse to plain text — the
    /// raw asterisks/backticks would otherwise show literally in the prose.
    /// Leading block markers (`# `, `> `, list bullets) are stripped first
    /// since the headline is a single line, not a document.
    private func renderInlineMarkdown(_ text: String) -> Text {
        let stripped = text.replacingOccurrences(
            of: #"^\s*(#{1,6}\s+|>\s+|[-*+]\s+|\d+\.\s+)"#,
            with: "",
            options: .regularExpression
        )
        if let attr = try? AttributedString(
            markdown: stripped,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attr)
        }
        return Text(stripped)
    }

    private func contextSection(_ ctx: ContextUsage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionHeader("Context")
                Spacer()
                Text("\(ctx.usedPercentage)%")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(contextBarColor(ctx.fractionUsed))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(nsColor: .separatorColor))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(contextBarColor(ctx.fractionUsed))
                        .frame(width: geo.size.width * min(ctx.fractionUsed, 1.0), height: 6)
                }
            }
            .frame(height: 6)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("In")
                        .font(.system(size: 11))
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    Text(formatTokens(ctx.totalInputTokens))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Color(nsColor: .secondaryLabelColor))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Out")
                        .font(.system(size: 11))
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    Text(formatTokens(ctx.totalOutputTokens))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Color(nsColor: .secondaryLabelColor))
                }
                if let cache = ctx.cacheReadTokens, cache > 0 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cache")
                            .font(.system(size: 10))
                            .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                        Text(formatTokens(cache))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Color(nsColor: .secondaryLabelColor))
                    }
                }
            }
            Text(formatTokens(ctx.contextWindowSize) + " window")
                .font(.system(size: 11))
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
        }
    }

    private func costSection(_ cost: CostInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Cost")
            Text(formatCost(cost.totalCostUsd))
                .font(.system(size: 20, weight: .medium, design: .monospaced))
                .foregroundColor(.primary)
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Duration")
                        .font(.system(size: 11))
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    Text(formatDuration(cost.totalDurationMs))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Color(nsColor: .secondaryLabelColor))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("API time")
                        .font(.system(size: 11))
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    Text(formatDuration(cost.totalApiDurationMs))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Color(nsColor: .secondaryLabelColor))
                }
            }
        }
    }


    private func collapsedNetworkSection(_ net: NetworkInfo) -> some View {
        let waitingSec = apiWaitSeconds
        let isActive = state.status == .thinking || state.status == .toolUse || state.status == .streaming
        let apiMs = net.apiMsTotal ?? 0
        let toolMs = net.toolMsTotal ?? 0
        return HStack(spacing: 8) {
            sectionHeader("Time")
            Spacer()
            if isActive, waitingSec >= 5 {
                Text("waiting \(waitingSec)s...")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(waitingSec > 15 ? .orange : Color(nsColor: .secondaryLabelColor))
            } else if apiMs + toolMs > 0 {
                timeStackedBar(apiMs: apiMs, toolMs: toolMs)
                    .frame(width: 70, height: 6)
                Text(formatDurationShort(apiMs + toolMs))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(nsColor: .secondaryLabelColor))
            } else if let last = net.lastToolMs {
                Text(formatLatency(last))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(latencyColor(last))
            }
        }
    }

    private func collapsedCostSection(_ cost: CostInfo) -> some View {
        HStack {
            sectionHeader("Cost")
            Spacer()
            Text(formatCost(cost.totalCostUsd))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(.primary)
        }
    }

    private func collapsedContextSection(_ ctx: ContextUsage) -> some View {
        HStack {
            sectionHeader("Context")
            Spacer()
            Text("\(ctx.usedPercentage)%")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(contextBarColor(ctx.fractionUsed))
        }
    }

    private func activitySection() -> some View {
        let isActive = state.status == .thinking || state.status == .toolUse || state.status == .streaming
        let waitingSec = apiWaitSeconds
        let isSlow = waitingSec > 15
        let dotColor: Color = isSlow ? .orange : (isActive ? .blue : Color(nsColor: .separatorColor))
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionHeader("Activity")
                Spacer()
                if isActive {
                    PulsingDot(color: dotColor)
                } else {
                    Circle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: 6, height: 6)
                }
            }
            activityChart()
        }
    }

    private func timeStackedBar(apiMs: Int, toolMs: Int) -> some View {
        let total = max(1, apiMs + toolMs)
        let apiFrac = Double(apiMs) / Double(total)
        return GeometryReader { geo in
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.blue)
                    .frame(width: geo.size.width * apiFrac)
                Rectangle()
                    .fill(Color.green)
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
        }
    }

    /// Bidirectional activity history. The horizontal mid-line is the
    /// baseline: Claude bars grow upward from it, tool bars grow downward.
    /// Bar height is proportional to the fraction of that second the bucket
    /// was busy. Bar color ramps from light desaturated blue → yellow →
    /// orange → red → dark red as the bucket's continuous-busy streak grows
    /// past 5/15/30/60s, so a hung call is obvious at a glance.
    private func activityChart() -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .trailing, spacing: 0) {
                Text("Claude")
                    .font(.system(size: 9))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    .frame(maxHeight: .infinity, alignment: .bottom)
                Text("Tools")
                    .font(.system(size: 9))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(height: 48)
            GeometryReader { geo in
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
                    let progress = max(0, min(1, ctx.date.timeIntervalSince(lastSampleTime) / Self.barDurationSecs))
                    let halfH = geo.size.height / 2
                    let columns = Self.activityWindow + 1
                    let spacing: CGFloat = 0
                    // Pitch = chart-visible-width / activityWindow keeps
                    // exactly `activityWindow` bars filling the visible area
                    // at progress=0; the +1th bar lives just past the right
                    // edge and slides in as `progress` ramps to 1.
                    let pitch = geo.size.width / CGFloat(Self.activityWindow)
                    let barW = max(0, pitch - spacing)
                    let totalW = pitch * CGFloat(columns) - spacing
                    let offset = -pitch * CGFloat(progress)
                    // Right-align: fill slots from the right so the newest
                    // sample lands at slot `columns-1` (offscreen-right,
                    // sliding into view as progress ramps to 1). Empty
                    // slots stay on the left until the buffer fills.
                    let firstUsedSlot = columns - activitySamples.count

                    HStack(alignment: .center, spacing: spacing) {
                        ForEach(0..<columns, id: \.self) { i in
                            let idx = i - firstUsedSlot
                            let s: ActivitySample = (idx >= 0 && idx < activitySamples.count)
                                ? activitySamples[idx]
                                : ActivitySample(claude: 0, tool: 0,
                                                  claudeStreakSecs: 0, toolStreakSecs: 0,
                                                  toolIsNewToolStart: false,
                                                  toolNames: [])
                            let toolTip = s.toolNames.joined(separator: ", ")
                            // Any non-zero sample gets at least `minVisible`
                            // of the half-height so very short tools (Read,
                            // Edit, Update — often <100ms) don't render as
                            // 1-px slivers. Preserves legibility without
                            // misreporting magnitude for longer activity.
                            let minVisible: Double = 0.15
                            let claudeH = s.claude > 0 ? max(minVisible, s.claude) : 0
                            let toolH   = s.tool   > 0 ? max(minVisible, s.tool)   : 0
                            VStack(spacing: 0) {
                                // Upper half — Claude bar pinned to the
                                // CENTERLINE via ZStack alignment: .bottom.
                                ZStack(alignment: .bottom) {
                                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                                    if claudeH > 0 {
                                        Rectangle()
                                            .fill(Self.intensityColor(streakSecs: s.claudeStreakSecs))
                                            .frame(height: halfH * claudeH)
                                    }
                                }
                                .frame(height: halfH)
                                // Lower half — Tool bar pinned to the
                                // CENTERLINE via ZStack alignment: .top.
                                // `padding(.leading)` is the 1-px inset
                                // marker when a fresh tool begins.
                                ZStack(alignment: .top) {
                                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                                    if toolH > 0 {
                                        Rectangle()
                                            .fill(Self.intensityColor(streakSecs: s.toolStreakSecs))
                                            .frame(height: halfH * toolH)
                                            .padding(.leading, s.toolIsNewToolStart ? 1 : 0)
                                            .help(toolTip)
                                    }
                                }
                                .frame(height: halfH)
                            }
                            .frame(width: barW)
                        }
                    }
                    .frame(width: totalW, alignment: .leading)
                    .offset(x: offset)
                }
            }
            .frame(height: 48)
            .clipped()
            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.10))
            .cornerRadius(2)
        }
        // Single continuous divider spanning labels + chart — overlaying
        // the outer HStack avoids the visible gap that two separate
        // per-column overlays would leave in the middle.
        .overlay(
            Rectangle()
                .fill(Color(nsColor: .secondaryLabelColor).opacity(0.7))
                .frame(height: 1)
        )
    }

    /// Streak duration → color ramp. The gradient peaks at 120 seconds of
    /// continuous busy: light blue → deep blue → green → orange → red.
    /// Stops are interpolated linearly in RGB.
    private static let intensityStops: [(Double, UInt32)] = [
        (0.00, 0xBFDCFF),  //   0s — light blue (idle)
        (0.22, 0x0B3A99),  //  26s — deep blue
        (0.48, 0x166534),  //  58s — green
        (0.78, 0xFF8A1F),  //  94s — orange
        (1.00, 0xDC2626),  // 120s+ — red
    ]
    private static let intensityMaxSecs: Double = 1800

    private static let debugLogPath: String = {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude-terminal")
        return (dir as NSString).appendingPathComponent("debug.log")
    }()

    private static func debugTimestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }

    private static func appendDebugLog(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: debugLogPath) {
            try? fm.createDirectory(
                atPath: (debugLogPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            fm.createFile(atPath: debugLogPath, contents: nil)
        }
        if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: debugLogPath)) {
            defer { try? h.close() }
            try? h.seekToEnd()
            try? h.write(contentsOf: data)
        }
    }

    private static func intensityColor(streakSecs: Double) -> Color {
        let t = max(0, min(1, streakSecs / intensityMaxSecs))
        if t >= intensityStops.last!.0 {
            return Color(hex: intensityStops.last!.1)
        }
        for i in 0..<(intensityStops.count - 1) {
            let (ta, ha) = intensityStops[i]
            let (tb, hb) = intensityStops[i + 1]
            if t >= ta && t < tb {
                let f = (t - ta) / (tb - ta)
                let ar = Double((ha >> 16) & 0xFF), ag = Double((ha >> 8) & 0xFF), ab = Double(ha & 0xFF)
                let br = Double((hb >> 16) & 0xFF), bg = Double((hb >> 8) & 0xFF), bb = Double(hb & 0xFF)
                return Color(
                    red:   (ar + (br - ar) * f) / 255,
                    green: (ag + (bg - ag) * f) / 255,
                    blue:  (ab + (bb - ab) * f) / 255
                )
            }
        }
        return Color(hex: intensityStops.first!.1)
    }

    /// 10Hz sub-sampler. Updates streak counters and accumulates 100ms
    /// fragments. At the 1-second boundary we emit one finalized sample —
    /// the chart animates the horizontal slide on its own via TimelineView,
    /// using `lastSampleTime` to interpolate the offset.
    ///
    /// Claude and Tool buckets are sampled independently: a sub-tick where
    /// the API is in flight counts toward Claude even if a tool is also
    /// running. Otherwise rapid tool chains mask the brief thinking gaps
    /// and the chart misleadingly looks like 100% tool work.
    private func tickActivitySubSample() {
        // When Claude is blocked on a permission prompt the session shows
        // status=tool_use but it isn't actually working — it's waiting on
        // the user. Treat that as zero activity so neither bar grows.
        let needsInput = state.needsInput == true
        // A tool that started and finished within a single 100ms tick
        // (very common for Read/Edit/Glob/Grep) won't be visible via the
        // status snapshot — but the hook will have bumped toolMsTotal.
        // Detecting a positive delta lets us still credit those samples.
        let cumulativeToolMs = state.network?.toolMsTotal ?? 0
        let toolJustFinished = cumulativeToolMs > lastObservedToolMsTotal
        lastObservedToolMsTotal = cumulativeToolMs
        let toolBusy = !needsInput
            && (!(state.activeTools ?? []).isEmpty
                || state.status == .toolUse
                || toolJustFinished)
        // Claude bar tracks only real LLM work — a tool starting ends the
        // Claude bar immediately. Ticks where a tool is running OR just
        // finished (caught by `toolJustFinished`) are credited to the
        // tool bar exclusively; otherwise a short sub-100ms tool gets
        // sampled as Claude because `status==.thinking` in the same tick.
        let claudeBusy = !needsInput && !toolBusy
            && (state.status == .thinking || state.status == .streaming)

        // Diagnostic: log state transitions to ~/.claude-terminal/debug.log
        // so we can verify that .thinking is actually observed between tools.
        let statusRaw = state.status.rawValue
        if statusRaw != loggedStatusRaw
            || claudeBusy != loggedClaudeBusy
            || toolBusy != loggedToolBusy {
            let toolCount = state.activeTools?.count ?? 0
            let line = "\(Self.debugTimestamp())  status=\(statusRaw) claudeBusy=\(claudeBusy) toolBusy=\(toolBusy) activeTools=\(toolCount)\n"
            Self.appendDebugLog(line)
            loggedStatusRaw = statusRaw
            loggedClaudeBusy = claudeBusy
            loggedToolBusy = toolBusy
        }

        if claudeBusy {
            subSampleClaude += 1
            claudeStreakSecs += 1.0 / Self.subSampleHz
        } else {
            claudeStreakSecs = 0
        }
        // Reset the tool hue ramp each time a fresh tool starts — the
        // streak measures how long *this* tool has been running, not the
        // cumulative run of back-to-back tools. Detect a new tool by any
        // active tool ID that wasn't present on the previous tick.
        let currentToolIds = Set((state.activeTools ?? []).map(\.id))
        let newToolStarted = !currentToolIds.subtracting(prevActiveToolIds).isEmpty
        prevActiveToolIds = currentToolIds
        if newToolStarted {
            toolStreakSecs = 0
            toolStartedThisWindow = true
        }
        for t in state.activeTools ?? [] where !toolNamesThisWindow.contains(t.tool) {
            toolNamesThisWindow.append(t.tool)
        }
        if toolBusy {
            subSampleTool += 1
            toolStreakSecs += 1.0 / Self.subSampleHz
        } else {
            toolStreakSecs = 0
        }
        subSampleCount += 1

        if subSampleCount >= Self.subSamplesPerSample {
            let denom = Double(Self.subSamplesPerSample)
            let sample = ActivitySample(
                claude: Double(subSampleClaude) / denom,
                tool: Double(subSampleTool) / denom,
                claudeStreakSecs: claudeStreakSecs,
                toolStreakSecs: toolStreakSecs,
                toolIsNewToolStart: toolStartedThisWindow,
                toolNames: toolNamesThisWindow
            )
            // Keep one extra bar offscreen on the right so we always have
            // something to slide into view as the HStack scrolls left.
            activitySamples.append(sample)
            let cap = Self.activityWindow + 1
            if activitySamples.count > cap {
                activitySamples.removeFirst(activitySamples.count - cap)
            }
            lastSampleTime = Date()
            subSampleClaude = 0
            subSampleTool = 0
            subSampleCount = 0
            toolStartedThisWindow = false
            toolNamesThisWindow = []
        }
    }

    private func formatDurationShort(_ ms: Int) -> String {
        let secs = ms / 1000
        if secs < 60 { return "\(secs)s" }
        let m = secs / 60
        let s = secs % 60
        return "\(m)m \(s)s"
    }

    private var apiWaitSeconds: Int {
        guard let sendMs = state.apiSendMs else { return 0 }
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        let elapsed = nowMs - sendMs
        return max(0, elapsed / 1000)
    }

    private var subagentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Subagents")
            ForEach(state.subagents) { agent in
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor(agent.status))
                        .frame(width: 6, height: 6)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(agent.name)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.primary)
                            if let tool = agent.currentTool {
                                Text(tool)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(toolColor(tool))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(toolColor(tool).opacity(0.12))
                                    .cornerRadius(3)
                            }
                        }
                        if let desc = agent.description {
                            Text(desc)
                                .font(.system(size: 12))
                                .foregroundColor(Color(nsColor: .secondaryLabelColor))
                                .lineLimit(1)
                        }
                        if let tool = agent.currentTool, let detail = agent.toolDetail, !detail.isEmpty {
                            Text(toolDetailLabel(tool, detail: detail))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }
                }
                .contextMenu {
                    Button("Force Quit") {
                        monitor.removeSubagent(agent.id)
                    }
                }
            }
        }
    }

    private var tasksSection: some View {
        let sorted = topologicallySorted(state.tasks)
        let depthMap = taskDepths(state.tasks)
        return VStack(alignment: .leading, spacing: 8) {
            let completed = state.tasks.filter { $0.status == "completed" }.count
            let total = state.tasks.count
            HStack {
                sectionHeader("Tasks")
                Spacer()
                Text("\(completed)/\(total)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
            }
            ForEach(sorted) { task in
                let depth = depthMap[task.id, default: 0]
                let isBlocked = taskIsBlocked(task)
                HStack(spacing: 0) {
                    if depth > 0 {
                        HStack(spacing: 0) {
                            ForEach(0..<depth, id: \.self) { i in
                                if i == depth - 1 {
                                    Image(systemName: "arrow.turn.down.right")
                                        .font(.system(size: 9))
                                        .foregroundColor(Color(nsColor: .separatorColor))
                                        .frame(width: 14)
                                } else {
                                    Color.clear.frame(width: 14)
                                }
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        if task.status == "in_progress" {
                            SpinningIcon(systemName: "arrow.trianglehead.2.clockwise", color: .blue)
                        } else if isBlocked {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 10))
                                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                        } else {
                            Image(systemName: taskIcon(task.status))
                                .font(.system(size: 13))
                                .foregroundColor(taskColor(task.status))
                        }
                        Text(task.subject)
                            .font(.system(size: 13, weight: task.status == "in_progress" ? .semibold : .regular))
                            .foregroundColor(
                                task.status == "completed" ? Color(nsColor: .tertiaryLabelColor) :
                                isBlocked ? Color(nsColor: .secondaryLabelColor) : .primary
                            )
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    private func documentsSection<S: Sequence>(_ docs: S, fullCount: Int) -> some View where S.Element == String {
        let paths = Array(docs)
        return VStack(alignment: .leading, spacing: 4) {
            documentsHeader(count: paths.count)
            ForEach(Array(paths.enumerated()), id: \.element) { index, path in
                documentCard(path: path, compact: index >= fullCount)
            }
        }
    }

    /// Section header with a leading disclosure triangle. Clicking anywhere
    /// on the header (triangle, label, or trailing count) toggles
    /// `documentsCollapsed`, which is persisted via @AppStorage and applies
    /// across all session windows.
    private func documentsHeader(count: Int) -> some View {
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

    private func documentCard(path: String, compact: Bool = false) -> some View {
        let isImage = ViewableDocument.isImage(path)
        let isMarkdown = ViewableDocument.isMarkdown(path)
        let meta = (compact || isImage) ? nil : DocumentExcerptCache.excerpt(for: path)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: documentIcon(path))
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

    private func abbreviateFilePath(_ path: String) -> String {
        let filename = (path as NSString).lastPathComponent
        let dir = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return dir.isEmpty ? filename : "\(dir)/\(filename)"
    }

    private func documentIcon(_ path: String) -> String {
        if ViewableDocument.isImage(path) { return "photo" }
        return "doc.text"
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

    private func taskIsBlocked(_ task: SessionTask) -> Bool {
        guard let blockers = task.blockedBy, !blockers.isEmpty else { return false }
        return blockers.contains { bid in
            state.tasks.contains { $0.id == bid && $0.status != "completed" }
        }
    }

    private func topologicallySorted(_ tasks: [SessionTask]) -> [SessionTask] {
        let ids = Set(tasks.map(\.id))
        var graph: [String: [String]] = [:]
        var inDegree: [String: Int] = [:]
        for t in tasks {
            graph[t.id] = []
            inDegree[t.id] = 0
        }
        for t in tasks {
            for bid in t.blockedBy ?? [] where ids.contains(bid) {
                graph[bid, default: []].append(t.id)
                inDegree[t.id, default: 0] += 1
            }
        }
        var queue = tasks.filter { inDegree[$0.id, default: 0] == 0 }.map(\.id)
        var order: [String] = []
        var idx = 0
        while idx < queue.count {
            let curr = queue[idx]
            idx += 1
            order.append(curr)
            for dep in graph[curr, default: []] {
                inDegree[dep, default: 0] -= 1
                if inDegree[dep, default: 0] == 0 {
                    queue.append(dep)
                }
            }
        }
        let taskMap = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        var result = order.compactMap { taskMap[$0] }
        let ordered = Set(order)
        result += tasks.filter { !ordered.contains($0.id) }
        return result
    }

    private func taskDepths(_ tasks: [SessionTask]) -> [String: Int] {
        let ids = Set(tasks.map(\.id))
        var depths: [String: Int] = [:]
        for t in tasks {
            depths[t.id] = 0
        }
        var changed = true
        while changed {
            changed = false
            for t in tasks {
                for bid in t.blockedBy ?? [] where ids.contains(bid) {
                    let newDepth = depths[bid, default: 0] + 1
                    if newDepth > depths[t.id, default: 0] {
                        depths[t.id] = newDepth
                        changed = true
                    }
                }
            }
        }
        return depths
    }

    // MARK: - Helpers

    private func abbreviatePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func permissionBadge(_ mode: String?) -> (label: String, color: Color)? {
        switch mode {
        case "bypassPermissions": return ("YOLO", .red)
        case "plan": return ("PLAN", .blue)
        default: return nil
        }
    }

    private var statusHeader: some View {
        let isActive = state.status != .idle && state.status != .disconnected
        return Text("STATUS")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(isActive ? statusColor(state.status) : Color(nsColor: .secondaryLabelColor))
            .tracking(0.5)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(Color(nsColor: .secondaryLabelColor))
            .textCase(.uppercase)
            .tracking(0.5)
    }

    private func statusColor(_ status: SessionStatus) -> Color {
        switch status {
        case .idle: return .gray
        case .thinking: return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 0.95, green: 0.65, blue: 0.15, alpha: 1)
                : NSColor(red: 0.75, green: 0.45, blue: 0.05, alpha: 1)
        })
        case .toolUse: return .blue
        case .streaming: return .green
        case .disconnected: return Color(nsColor: .separatorColor)
        }
    }

    private func statusLabel(_ status: SessionStatus) -> String {
        switch status {
        case .idle: return "Idle"
        case .thinking: return "Working"
        case .toolUse: return "Using tool"
        case .streaming: return "Streaming"
        case .disconnected: return "Disconnected"
        }
    }

    private func contextBarColor(_ fraction: Double) -> Color {
        if fraction > 0.9 { return .red }
        if fraction > 0.7 { return .orange }
        return .blue
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000.0)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000.0)
        }
        return "\(count)"
    }

    private func formatCost(_ usd: Double) -> String {
        // Clamp tiny negatives (floating-point noise after a reset) to zero.
        let v = max(0, usd)
        if v < 0.01 {
            return String(format: "$%.4f", v)
        }
        return String(format: "$%.2f", v)
    }

    private func formatDuration(_ ms: Int) -> String {
        let seconds = max(0, ms) / 1000
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        let secs = seconds % 60
        if minutes < 60 { return "\(minutes)m \(secs)s" }
        let hours = minutes / 60
        let mins = minutes % 60
        return "\(hours)h \(mins)m"
    }

    private func formatLatency(_ ms: Int) -> String {
        if ms < 1000 { return "\(ms)ms" }
        return String(format: "%.1fs", Double(ms) / 1000.0)
    }

    private func latencyColor(_ ms: Int) -> Color {
        if ms > 10000 { return .red }
        if ms > 5000 { return .orange }
        return .green
    }

    private func toolVerb(_ tool: String) -> String {
        switch tool {
        case "Bash": return "Running command"
        case "Read": return "Reading file"
        case "Write": return "Writing file"
        case "Edit": return "Editing file"
        case "Grep": return "Searching content"
        case "Glob": return "Finding files"
        case "Agent": return "Spawning agent"
        case "WebFetch": return "Fetching URL"
        case "WebSearch": return "Searching web"
        case "TaskCreate": return "Creating task"
        case "TaskUpdate": return "Updating task"
        case "LSP": return "Code intelligence"
        case "EnterPlanMode": return "Planning"
        case "ExitPlanMode": return "Plan ready"
        case "AskUserQuestion": return "Asking question"
        default: return "Using tool"
        }
    }

    private func toolDetailLabel(_ tool: String, detail: String) -> String {
        switch tool {
        case "Bash":
            return summarizeBashCommand(detail)
        case "Read":
            return "reading \(abbreviateFilePath(detail))"
        case "Edit":
            return "editing \(abbreviateFilePath(detail))"
        case "Write":
            return abbreviateFilePath(detail)
        case "Grep":
            return detail
        case "Glob":
            return detail
        case "Agent":
            return detail
        case "WebFetch":
            if let url = URL(string: detail) {
                return url.host ?? detail
            }
            return detail
        case "WebSearch":
            return "\"\(detail)\""
        case "TaskCreate":
            return detail
        case "TaskUpdate":
            return detail
        default:
            return detail
        }
    }

    private func toolColor(_ tool: String) -> Color {
        switch tool {
        // File / shell / search tools share the same orange treatment so the
        // user's eye doesn't have to juggle a palette for common operations.
        case "Bash", "Read", "Edit", "Write", "Grep", "Glob": return .orange
        case "Agent": return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor.systemYellow
                : NSColor(red: 0.6, green: 0.5, blue: 0.0, alpha: 1)
        })
        case "WebFetch", "WebSearch": return Color(nsColor: .systemTeal)
        case "TaskCreate", "TaskUpdate": return .green
        default: return .blue
        }
    }

    private func taskIcon(_ status: String) -> String {
        switch status {
        case "completed": return "checkmark.circle.fill"
        case "in_progress": return "circle.dotted"
        default: return "circle"
        }
    }

    private func taskColor(_ status: String) -> Color {
        switch status {
        case "completed": return .green
        case "in_progress": return .blue
        default: return Color(nsColor: .tertiaryLabelColor)
        }
    }
}

extension Notification.Name {
    static let renameSession = Notification.Name("org.claire.claude-terminal.renameSession")
    static let sessionListDidChange = Notification.Name("org.claire.claude-terminal.sessionListDidChange")
}

private struct SpinningIcon: View {
    let systemName: String
    let color: Color
    @State private var rotating = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13))
            .foregroundColor(color)
            .rotationEffect(.degrees(rotating ? 360 : 0))
            .animation(
                .linear(duration: 1.5).repeatForever(autoreverses: false),
                value: rotating
            )
            .onAppear { rotating = true }
    }
}

/// Condense a shell command to just the command names that would run, keeping
/// the top-level chain operators (`&&`, `||`, `;`). Examples:
///   `gcc -O2 foo.c -o foo` → `gcc`
///   `echo hi && date && uptime && ls -la /x | head -5` → `echo && date && uptime && ls`
///   `bash -c 'make test && git push'` → `make && git push`
/// Left-hand side of a pipe only; env assignments (`FOO=bar cmd`) stripped.
/// Falls back to the original string if parsing produces nothing.
fileprivate func summarizeBashCommand(_ command: String) -> String {
    let unwrapped = unwrapShellDashC(command) ?? command
    let parts = splitBashTopLevel(unwrapped)
    if parts.isEmpty { return command }
    var out = ""
    for (i, part) in parts.enumerated() {
        if i > 0 { out += " \(part.separator) " }
        out += part.name
    }
    return out.isEmpty ? command : out
}

fileprivate func splitBashTopLevel(_ s: String) -> [(separator: String, name: String)] {
    var result: [(String, String)] = []
    var buffer = ""
    var sep = ""
    var quote: Character? = nil
    var paren = 0
    let chars = Array(s)
    var i = 0

    func flush() {
        let name = firstBashCommandToken(buffer)
        if !name.isEmpty { result.append((sep, name)) }
        buffer = ""
    }

    while i < chars.count {
        let c = chars[i]
        if let q = quote {
            buffer.append(c)
            if c == q { quote = nil }
            i += 1; continue
        }
        if c == "'" || c == "\"" { quote = c; buffer.append(c); i += 1; continue }
        if c == "(" { paren += 1; buffer.append(c); i += 1; continue }
        if c == ")" { if paren > 0 { paren -= 1 }; buffer.append(c); i += 1; continue }
        if paren == 0 {
            if c == ";" { flush(); sep = ";"; i += 1; continue }
            if (c == "&" || c == "|") && i + 1 < chars.count && chars[i + 1] == c {
                flush(); sep = "\(c)\(c)"; i += 2; continue
            }
        }
        buffer.append(c)
        i += 1
    }
    flush()
    return result
}

fileprivate func firstBashCommandToken(_ segment: String) -> String {
    var s = segment.trimmingCharacters(in: .whitespaces)
    // Strip leading env assignments: FOO=bar.
    while let m = s.range(of: #"^[A-Za-z_][A-Za-z0-9_]*=\S*\s+"#, options: .regularExpression) {
        s = String(s[m.upperBound...])
    }
    // Keep only the left side of a pipe chain.
    if let pipe = s.firstIndex(of: "|") {
        s = String(s[..<pipe]).trimmingCharacters(in: .whitespaces)
    }
    return s.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
}

fileprivate func unwrapShellDashC(_ s: String) -> String? {
    let prefixes = ["bash -c ", "sh -c ", "zsh -c ", "/bin/bash -c ", "/bin/sh -c "]
    for p in prefixes where s.hasPrefix(p) {
        var body = String(s.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
        if let quote = body.first, quote == "'" || quote == "\"" {
            body = String(body.dropFirst())
            if let end = body.lastIndex(of: quote) {
                body = String(body[..<end])
            }
        }
        return body
    }
    return nil
}

private struct ToolDetailText: View {
    let label: String
    let rawDetail: String
    var color: Color = .primary

    var body: some View {
        Text(label)
            .font(.system(size: 12))
            .foregroundColor(color)
            .lineLimit(4)
            .truncationMode(.middle)
            .help(rawDetail)
    }
}

/// Hover affordance for document cards — swaps the cursor from the i-beam
/// (caused by the sidebar-wide `.textSelection(.enabled)`) to a pointing
/// hand, and lifts the card with a brighter background + subtle drop
/// shadow so it visibly reads as clickable.
/// Zero-delay tooltip — the AppKit `.help()` modifier has a built-in
/// ~1-2s delay that isn't configurable. This shows a small popover-style
/// label as soon as the pointer enters the view, anchored below it.
private struct InstantTooltip: ViewModifier {
    let text: String
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .onHover { hovered = $0 }
            .overlay(alignment: .topLeading) {
                if hovered, !text.isEmpty {
                    Text(text)
                        .font(.system(size: 11))
                        .foregroundColor(.primary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        // Use `textBackgroundColor` (flat opaque white /
                        // near-black) instead of `windowBackgroundColor` —
                        // the latter can render semi-translucently on top
                        // of the sidebar's vibrancy material, letting
                        // content behind the window bleed into the
                        // tooltip as ghost text.
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(nsColor: .textBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 1)
                        .fixedSize()
                        .offset(x: 0, y: 22)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .zIndex(100)
                }
            }
    }
}

private struct DocumentCardHoverModifier: ViewModifier {
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

private struct PulsingDot: View {
    let color: Color
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .opacity(pulsing ? 0.3 : 1.0)
            .animation(
                .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                value: pulsing
            )
            .onAppear { pulsing = true }
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}
