import SwiftUI

struct SidebarView: View {
    @ObservedObject var monitor: SessionMonitor
    @ObservedObject var tabState: DocumentTabState
    var width: CGFloat = 280

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
                if let docs = state.documents?.filter({ FileManager.default.fileExists(atPath: $0) }), !docs.isEmpty {
                    sectionCard { documentsSection(docs) }
                }

                Spacer(minLength: 0)

                if let net = state.network, net.hasData {
                    sectionCard {
                        if collapse >= 1 {
                            collapsedNetworkSection(net)
                        } else {
                            networkSection(net)
                        }
                    }
                }
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
    }

    private func collapseLevel(availableHeight: CGFloat) -> Int {
        var top: CGFloat = 90 + 12 + 94
        if !state.subagents.isEmpty {
            top += 12 + CGFloat(32 + state.subagents.count * 52) + 24
        }
        if state.tasks.contains(where: { $0.status != "completed" }) {
            top += 12 + CGFloat(32 + state.tasks.count * 32) + 24
        }
        let netFull: CGFloat = state.network?.hasData == true ? 12 + 80 : 0
        let netSmall: CGFloat = state.network?.hasData == true ? 12 + 44 : 0
        let costFull: CGFloat = state.cost != nil ? 12 + 124 : 0
        let costSmall: CGFloat = state.cost != nil ? 12 + 44 : 0
        let ctxFull: CGFloat = state.contextUsage != nil ? 12 + 144 : 0
        let ctxSmall: CGFloat = state.contextUsage != nil ? 12 + 44 : 0

        if top + netFull + ctxFull + costFull <= availableHeight { return 0 }
        if top + netSmall + ctxFull + costFull <= availableHeight { return 1 }
        if top + netSmall + ctxFull + costSmall <= availableHeight { return 2 }
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
                Text(abbreviatePath(dir))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    .lineLimit(1)
                    .truncationMode(.middle)
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
                Text(model)
                    .font(.system(size: 13))
                    .foregroundColor(Color(nsColor: .secondaryLabelColor))
            }
            if let turns = state.conversationTurns {
                Text("\(turns) turns")
                    .font(.system(size: 12))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
            }
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusHeader
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor(state.status))
                    .frame(width: 8, height: 8)
                Text(statusLabel(state.status))
                    .font(.system(size: 14))
                    .foregroundColor(.primary)
            }
            if let active = state.activeTools, active.count > 1 {
                ForEach(active) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(entry.tool)
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .foregroundColor(toolColor(entry.tool))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(toolColor(entry.tool).opacity(0.12))
                                .cornerRadius(4)
                            Text(toolVerb(entry.tool))
                                .font(.system(size: 12))
                                .foregroundColor(Color(nsColor: .secondaryLabelColor))
                        }
                        if let detail = entry.detail, !detail.isEmpty {
                            ToolDetailText(
                                label: toolDetailLabel(entry.tool, detail: detail),
                                rawDetail: detail
                            )
                        }
                    }
                }
            } else if let tool = state.currentToolName {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(tool)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundColor(toolColor(tool))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(toolColor(tool).opacity(0.12))
                            .cornerRadius(4)
                        Text(toolVerb(tool))
                            .font(.system(size: 12))
                            .foregroundColor(Color(nsColor: .secondaryLabelColor))
                    }
                    if let detail = state.toolDetail, !detail.isEmpty {
                        ToolDetailText(
                            label: toolDetailLabel(tool, detail: detail),
                            rawDetail: detail
                        )
                    }
                }
            }
        }
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
        return HStack {
            sectionHeader("API Latency")
            Spacer()
            if isActive, waitingSec >= 5 {
                Text("waiting \(waitingSec)s...")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(waitingSec > 15 ? .orange : Color(nsColor: .secondaryLabelColor))
            } else if let last = net.lastToolMs {
                Text(formatLatency(last))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(latencyColor(last))
            } else if let avg = net.avgApiMsPerTurn {
                Text(formatLatency(avg) + "/turn")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(Color(nsColor: .secondaryLabelColor))
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

    private func networkSection(_ net: NetworkInfo) -> some View {
        let isActive = state.status == .thinking || state.status == .toolUse || state.status == .streaming
        let waitingSec = apiWaitSeconds
        let isSlow = waitingSec > 15
        let dotColor: Color = isSlow ? .orange : (isActive ? .blue : Color(nsColor: .separatorColor))
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionHeader("API Latency")
                Spacer()
                if isActive {
                    PulsingDot(color: dotColor)
                } else {
                    Circle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: 6, height: 6)
                }
            }
            if isActive, waitingSec >= 5 {
                Text("waiting \(waitingSec)s...")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(isSlow ? .orange : Color(nsColor: .secondaryLabelColor))
            }
            HStack(spacing: 12) {
                if let last = net.lastToolMs {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Last")
                            .font(.system(size: 11))
                            .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                        Text(formatLatency(last))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(latencyColor(last))
                    }
                }
                if let avg = net.avgApiMsPerTurn {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Avg/turn")
                            .font(.system(size: 11))
                            .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                        Text(formatLatency(avg))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Color(nsColor: .secondaryLabelColor))
                    }
                }
                if let pct = net.apiTimePercent {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("API")
                            .font(.system(size: 11))
                            .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                        Text("\(pct)%")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Color(nsColor: .secondaryLabelColor))
                    }
                }
            }
        }
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

    private func documentsSection(_ docs: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Documents")
            ForEach(docs, id: \.self) { path in
                documentCard(path: path)
            }
        }
    }

    private func documentCard(path: String) -> some View {
        let meta = DocumentExcerptCache.excerpt(for: path)
        let isMarkdown = path.lowercased().hasSuffix(".md") || path.lowercased().hasSuffix(".markdown")
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
            if !meta.title.isEmpty || !meta.excerpt.isEmpty {
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
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.15))
        )
        .contentShape(Rectangle())
        .help(path)
        .onTapGesture {
            if isMarkdown {
                tabState.open(path: path)
                monitor.addDocument(path: path)
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        }
        .contextMenu {
            if isMarkdown {
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
        }
    }

    private func abbreviateFilePath(_ path: String) -> String {
        let filename = (path as NSString).lastPathComponent
        let dir = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return dir.isEmpty ? filename : "\(dir)/\(filename)"
    }

    private func documentIcon(_ path: String) -> String {
        return "doc.text"
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
        case .thinking: return "Thinking..."
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
            return "$ \(detail)"
        case "Read", "Write", "Edit":
            let filename = (detail as NSString).lastPathComponent
            let dir = ((detail as NSString).deletingLastPathComponent as NSString).lastPathComponent
            return dir.isEmpty ? filename : "\(dir)/\(filename)"
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
        case "Bash": return .orange
        case "Read": return Color(nsColor: .systemTeal)
        case "Edit", "Write": return .pink
        case "Grep", "Glob": return .purple
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

private struct ToolDetailText: View {
    let label: String
    let rawDetail: String

    var body: some View {
        if rawDetail.hasPrefix("/"), FileManager.default.fileExists(atPath: rawDetail) {
            Text(label)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.blue)
                .underline()
                .lineLimit(4)
                .truncationMode(.middle)
                .onTapGesture {
                    NSWorkspace.shared.open(URL(fileURLWithPath: rawDetail))
                }
                .help(rawDetail)
        } else {
            Text(label)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                .lineLimit(4)
                .truncationMode(.middle)
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
