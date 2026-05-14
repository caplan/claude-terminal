import AppKit
import SwiftUI

private extension Color {
    init(hex: UInt32) {
        self.init(
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >>  8) & 0xFF) / 255,
            blue:  Double( hex        & 0xFF) / 255
        )
    }
}

/// Section card content — the "Activity" header + bidirectional bar chart.
/// Self-contained: owns its own sample buffer and 10Hz sub-sampler, drives
/// the chart's TimelineView for the slide animation, and renders a pulsing
/// status dot in the header that turns orange when the API has been waiting
/// >15s. Caller passes the live `SessionState` and the API-wait duration.
struct ActivityChartView: View {
    let state: SessionState
    let apiWaitSeconds: Int

    @State private var activitySamples: [ActivitySample] = []
    @State private var subSampleClaude: Int = 0
    @State private var subSampleTool: Int = 0
    @State private var subSampleCount: Int = 0
    @State private var claudeStreakSecs: Double = 0
    @State private var toolStreakSecs: Double = 0
    @State private var lastSampleTime: Date = Date()
    @State private var loggedClaudeBusy: Bool? = nil
    @State private var loggedToolBusy: Bool? = nil
    @State private var loggedStatusRaw: String? = nil
    @State private var lastObservedToolMsTotal: Int = 0
    @State private var prevActiveToolIds: Set<String> = []
    @State private var toolStartedThisWindow: Bool = false
    @State private var toolNamesThisWindow: [String] = []

    static let activityWindow = 60
    static let subSampleHz: Double = 10
    static let barDurationSecs: Double = 3
    static let subSamplesPerSample = Int(subSampleHz * barDurationSecs)

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

    var body: some View {
        let isActive = state.status == .thinking || state.status == .toolUse || state.status == .streaming
        let isSlow = apiWaitSeconds > 15
        let dotColor: Color = isSlow ? .orange : (isActive ? .blue : Color(nsColor: .separatorColor))
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Activity")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(nsColor: .secondaryLabelColor))
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
                if isActive {
                    PulsingDot(color: dotColor)
                } else {
                    Circle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: 6, height: 6)
                }
            }
            chart
        }
        .onReceive(Timer.publish(every: 1.0 / Self.subSampleHz, on: .main, in: .common).autoconnect()) { _ in
            tickActivitySubSample()
        }
    }

    /// Bidirectional activity history. The horizontal mid-line is the
    /// baseline: Claude bars grow upward from it, tool bars grow downward.
    /// Bar height is proportional to the fraction of that second the bucket
    /// was busy. Bar color ramps from light desaturated blue → yellow →
    /// orange → red → dark red as the bucket's continuous-busy streak grows
    /// past 5/15/30/60s, so a hung call is obvious at a glance.
    private var chart: some View {
        HStack(spacing: 6) {
            VStack(alignment: .trailing, spacing: 0) {
                Text("Claude")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(Color(nsColor: .secondaryLabelColor))
                    .frame(maxHeight: .infinity, alignment: .bottom)
                Text("Tools")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(Color(nsColor: .secondaryLabelColor))
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
                            // Minimum visible height per bucket. Tools get
                            // a much higher floor because tool events are
                            // usually 30-60 ms blips in 3s windows, which
                            // otherwise render as near-invisible slivers
                            // next to full-height Claude neighbors. Claude
                            // bars need little help since pure thinking
                            // typically spans most of a 3s window.
                            let claudeH = s.claude > 0 ? max(0.15, s.claude) : 0
                            let toolH   = s.tool   > 0 ? max(0.50, s.tool)   : 0
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

    /// Streak duration → color ramp. The gradient peaks at 20 minutes of
    /// continuous busy: light blue → deep blue → green → orange → red.
    /// Stops are interpolated linearly in RGB.
    private static let intensityStops: [(Double, UInt32)] = [
        (0.00, 0xBFDCFF),  //     0s — light blue (idle)
        (0.22, 0x0B3A99),  //   264s — deep blue
        (0.48, 0x166534),  //   576s — green
        (0.78, 0xFF8A1F),  //   936s — orange
        (1.00, 0xDC2626),  //  1200s+ — red
    ]
    private static let intensityMaxSecs: Double = 1200

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
