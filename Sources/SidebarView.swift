import SwiftUI
import UniformTypeIdentifiers

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
    /// Drives the instant tooltip on the context bar. .help() uses the
    /// system tooltip, which has a ~1s delay; .onHover into a SwiftUI
    /// overlay shows immediately.
    @State private var contextBarHovering = false
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

                if let pr = state.pullRequest {
                    sectionCard { prSection(pr) }
                }

                if !state.subagents.isEmpty {
                    sectionCard { SubagentsSection(monitor: monitor) }
                }
                if state.tasks.contains(where: { $0.status != "completed" }) {
                    sectionCard { TasksSection(monitor: monitor) }
                }
                // state.documents is pre-filtered for file existence in
                // SessionMonitor.readAndDecode; trust it here to avoid stat
                // syscalls on every SwiftUI redraw.
                if let docs = state.documents, !docs.isEmpty {
                    if documentsCollapsed {
                        // Collapsed: just the header card with the disclosure
                        // triangle + count. Doesn't expand to fill height, so
                        // the bottom sections move up.
                        sectionCard { DocumentsHeader(count: docs.count) }
                        Spacer(minLength: 0)
                    } else {
                        let fullCount = fullSizeDocCount(
                            docsCount: docs.count,
                            availableHeight: geo.size.height - 32,
                            collapse: collapse
                        )
                        ScrollView(.vertical, showsIndicators: false) {
                            sectionCard {
                                DocumentsSection(
                                    docs: docs.reversed(),
                                    fullCount: fullCount,
                                    monitor: monitor,
                                    tabState: tabState
                                )
                            }
                        }
                        .frame(maxHeight: .infinity)
                    }
                } else {
                    Spacer(minLength: 0)
                }

                sectionCard { ActivityChartView(state: state, apiWaitSeconds: apiWaitSeconds) }
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
            // Render the hover tooltip in its own NSPanel (via TooltipWindow)
            // so it lives outside the sidebar's vibrancy material — otherwise
            // SwiftUI overlays composite against the vibrancy and bleed.
            .onHover { isIn in
                if isIn {
                    TooltipWindow.shared.show(text: tooltip, anchor: NSEvent.mouseLocation)
                } else {
                    TooltipWindow.shared.hide()
                }
            }
        }
    }

    // MARK: - PR section
    //
    // Claude Code's statusline `pr` payload only includes `number`, `url`,
    // and `review_state` — the field is dropped entirely once a PR closes
    // or merges, so we only ever see live PRs here. The state pill therefore
    // resolves to "Draft" (when review_state == "draft") or "Open"; the
    // closed/merged styles are kept available for future data sources.
    @ViewBuilder
    private func prSection(_ pr: PullRequest) -> some View {
        let style = prStateStyle(reviewState: pr.reviewState)
        // Build the PR number label as a plain String and render via
        // Text(verbatim:) so SwiftUI's LocalizedStringKey path doesn't
        // grouping-format it (otherwise #2356 renders as #2,356).
        let numberLabel = "#" + String(pr.number)
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "Pull Request")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(nsColor: .secondaryLabelColor))
                .textCase(.uppercase)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            HStack(spacing: 8) {
                prStatePill(style)
                if let urlString = pr.url, let url = URL(string: urlString) {
                    Link(destination: url) {
                        Text(verbatim: numberLabel)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundColor(.blue)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .onHover { isHovered in
                        if isHovered { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                } else {
                    Text(verbatim: numberLabel)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                Spacer(minLength: 0)
                if let review = prReviewLabel(pr.reviewState, prState: style.state) {
                    Text(verbatim: review.label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(review.color)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(review.color.opacity(0.15))
                        .cornerRadius(3)
                }
            }
        }
    }

    private enum PRState { case open, draft, merged, closed }

    private struct PRStateStyle {
        let state: PRState
        let label: String
        let icon: String
        let color: Color
    }

    private func prStateStyle(reviewState: String?) -> PRStateStyle {
        if reviewState == "draft" {
            return PRStateStyle(
                state: .draft,
                label: "Draft",
                icon: "arrow.triangle.pull",
                color: Color(nsColor: .secondaryLabelColor)
            )
        }
        return PRStateStyle(
            state: .open,
            label: "Open",
            icon: "arrow.triangle.pull",
            color: Color(red: 0.18, green: 0.55, blue: 0.27) // GitHub open green
        )
    }

    @ViewBuilder
    private func prStatePill(_ style: PRStateStyle) -> some View {
        HStack(spacing: 4) {
            Image(systemName: style.icon)
                .font(.system(size: 10, weight: .bold))
            Text(verbatim: style.label)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(style.color)
        )
    }

    private func prReviewLabel(_ reviewState: String?, prState: PRState)
        -> (label: String, color: Color)?
    {
        guard let rs = reviewState, !rs.isEmpty, prState != .draft else { return nil }
        switch rs {
        case "approved":
            return ("approved", .green)
        case "changes_requested":
            return ("changes requested", .red)
        case "pending":
            return ("review pending", Color(nsColor: .secondaryLabelColor))
        default:
            return (rs.replacingOccurrences(of: "_", with: " "),
                    Color(nsColor: .secondaryLabelColor))
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
                    .contentShape(Rectangle())
                    .onHover { isHovered in
                        if isHovered {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
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
            Text(statusLabel(state.status, justStopped: justStopped, silentEndTurn: silentEndTurn))
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
        let snap = monitor.transcript
        let unusedPct = snap.contextUnusedPct ?? 0
        let usedFrac = min(ctx.fractionUsed, 1.0)
        let wastedFrac = usedFrac * Double(unusedPct) / 100.0
        let inCtxTokens = snap.lastTurnPromptTokens
            ?? Int(Double(ctx.contextWindowSize) * usedFrac)
        let deadTokens = snap.contextUnusedTokens ?? 0
        let trackedTokens = snap.contextTrackedTokens ?? 0
        let tooltip: String = {
            let lead = "\(formatTokens(inCtxTokens)) tokens in context"
            guard deadTokens > 0, trackedTokens > 0 else { return lead }
            let windowKey = UserDefaults.standard.integer(forKey: "contextWasteWindowTurns")
            let windowTurns = windowKey > 0 ? windowKey : ContextWasteTracker.defaultWindowTurns
            var msg = "\(lead). In the last \(windowTurns) turns, of \(formatTokens(trackedTokens)) tracked tokens, \(formatTokens(deadTokens)) were never re-referenced."
            let dead = snap.contextDeadArtifacts
            if !dead.isEmpty {
                msg += "\n\nTop dead artifacts:"
                for d in dead {
                    let label = d.tool.isEmpty ? d.key : "\(d.key)  (\(d.tool))"
                    msg += "\n  \(formatTokens(d.estTokens).padding(toLength: 6, withPad: " ", startingAt: 0))  \(label)"
                }
            }
            return msg
        }()
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionHeader("Context")
                Spacer()
                Text("\(ctx.usedPercentage)%")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(contextBarColor(ctx.fractionUsed))
            }
            GeometryReader { geo in
                let totalW = geo.size.width * usedFrac
                // Floor orange at 3px when waste >0 so a 2% sliver isn't
                // sub-pixel. Take it out of the blue half so the total bar
                // still equals usedFrac * geo.width.
                let rawOrange = geo.size.width * wastedFrac
                let orangeW = (wastedFrac > 0) ? max(rawOrange, min(3, totalW)) : 0
                let blueW = max(0, totalW - orangeW)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(nsColor: .separatorColor))
                        .frame(height: 6)
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(Color.blue)
                            .frame(width: blueW, height: 6)
                        Rectangle()
                            .fill(Color.orange)
                            .frame(width: orangeW, height: 6)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
            .frame(height: 6)
            .contentShape(Rectangle())
            .onHover { isIn in
                contextBarHovering = isIn
                if isIn {
                    TooltipWindow.shared.show(text: tooltip, anchor: NSEvent.mouseLocation)
                } else {
                    TooltipWindow.shared.hide()
                }
            }
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

    // MARK: - Helpers

    private func abbreviatePath(_ path: String) -> String { sidebarAbbreviatePath(path) }

    private func permissionBadge(_ mode: String?) -> (label: String, color: Color)? {
        sidebarPermissionBadge(mode)
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

    private func statusColor(_ status: SessionStatus) -> Color { sidebarStatusColor(status) }
    private func statusLabel(
        _ status: SessionStatus,
        justStopped: Bool = false,
        silentEndTurn: Bool = false
    ) -> String {
        sidebarStatusLabel(status, justStopped: justStopped, silentEndTurn: silentEndTurn)
    }

    /// True for the ~10s window after status flips to .idle, but only once
    /// we've seen at least one host assistant message — keeps a fresh
    /// session from flashing "Done" before any work has happened. The
    /// transcript snapshot is `@Published`, so a late-arriving final
    /// assistant line will trigger a re-evaluation here without an explicit
    /// debounce.
    private var justStopped: Bool {
        guard state.status == .idle,
              monitor.transcript.hasSeenAssistant,
              let at = idleAt else { return false }
        return Date().timeIntervalSince(at) < 10
    }

    /// True only inside the justStopped window, when the most recent host
    /// assistant message had no text. Drives the "Done · no reply" label.
    private var silentEndTurn: Bool {
        justStopped && !monitor.transcript.lastAssistantHadText
    }
    private func contextBarColor(_ fraction: Double) -> Color { sidebarContextBarColor(fraction) }
    private func formatTokens(_ count: Int) -> String { sidebarFormatTokens(count) }
    private func formatCost(_ usd: Double) -> String { sidebarFormatCost(usd) }
    private func formatDuration(_ ms: Int) -> String { sidebarFormatDuration(ms) }
    private func formatLatency(_ ms: Int) -> String { sidebarFormatLatency(ms) }
    private func latencyColor(_ ms: Int) -> Color { sidebarLatencyColor(ms) }
    private func toolVerb(_ tool: String) -> String { sidebarToolVerb(tool) }
    private func toolDetailLabel(_ tool: String, detail: String) -> String {
        sidebarToolDetailLabel(tool, detail: detail)
    }
    private func toolColor(_ tool: String) -> Color { sidebarToolColor(tool) }
    private func taskIcon(_ status: String) -> String { sidebarTaskIcon(status) }
    private func taskColor(_ status: String) -> Color { sidebarTaskColor(status) }
}

extension Notification.Name {
    static let renameSession = Notification.Name("org.claire.claude-terminal.renameSession")
    static let sessionListDidChange = Notification.Name("org.claire.claude-terminal.sessionListDidChange")
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
