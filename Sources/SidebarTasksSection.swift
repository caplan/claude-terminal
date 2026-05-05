import AppKit
import SwiftUI

/// Section card content — task list with topological ordering, depth-based
/// indentation, and a leading icon that reflects status (spinning for
/// in-progress, locked for blocked, checkmark for completed). The header
/// shows a `completed/total` counter on the right.
struct TasksSection: View {
    @ObservedObject var monitor: SessionMonitor

    private var state: SessionState { monitor.state }

    var body: some View {
        let sorted = topologicallySorted(state.tasks)
        let depthMap = taskDepths(state.tasks)
        let completed = state.tasks.filter { $0.status == "completed" }.count
        let total = state.tasks.count
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tasks")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(nsColor: .secondaryLabelColor))
                    .textCase(.uppercase)
                    .tracking(0.5)
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
                            Image(systemName: sidebarTaskIcon(task.status))
                                .font(.system(size: 13))
                                .foregroundColor(sidebarTaskColor(task.status))
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

    private func taskIsBlocked(_ task: SessionTask) -> Bool {
        guard let blockers = task.blockedBy, !blockers.isEmpty else { return false }
        return blockers.contains { bid in
            state.tasks.contains { $0.id == bid && $0.status != "completed" }
        }
    }
}

func topologicallySorted(_ tasks: [SessionTask]) -> [SessionTask] {
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

func taskDepths(_ tasks: [SessionTask]) -> [String: Int] {
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

struct SpinningIcon: View {
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
