import Foundation

// claude-terminal-hook: Replaces the Python update-status.sh and statusline.sh.
// Invoked by Claude Code hooks (subcommand `hook`) and statusLine (subcommand
// `statusline`). Reads JSON from stdin, updates
// ~/.claude-terminal/sessions/<id>/status.json, and writes a compact status line
// to stdout for the `statusline` subcommand.

// MARK: - Entry point

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: \(args.first ?? "claude-terminal-hook") <hook|statusline>\n".utf8))
    exit(2)
}

let sessionId = ProcessInfo.processInfo.environment["CLAUDE_TERMINAL_SESSION_ID"] ?? ""
if sessionId.isEmpty { exit(0) }

let home = FileManager.default.homeDirectoryForCurrentUser.path
let statusDir = "\(home)/.claude-terminal/sessions/\(sessionId)"
let statusFile = "\(statusDir)/status.json"
let lockFile = "\(statusDir)/.status.lock"
let persistFile = "\(home)/.claude-terminal/cost-by-session.json"

try? FileManager.default.createDirectory(atPath: statusDir, withIntermediateDirectories: true)

switch args[1] {
case "hook":
    runHook()
case "statusline":
    runStatusLine()
default:
    FileHandle.standardError.write(Data("unknown subcommand: \(args[1])\n".utf8))
    exit(2)
}

// MARK: - Lock / IO helpers

/// Acquire an exclusive flock on the status file for the read-modify-write
/// cycle. Returns a closure the caller must invoke to release.
func acquireLock() -> () -> Void {
    let fd = open(lockFile, O_CREAT | O_WRONLY, 0o644)
    if fd < 0 { return {} }
    flock(fd, LOCK_EX)
    return {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

func readState() -> [String: Any] {
    guard let data = FileManager.default.contents(atPath: statusFile),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return ["status": "disconnected", "subagents": [], "tasks": []]
    }
    var state = obj
    // Swift's CostInfo decoder requires all fields; drop any bad baseline.
    if let bl = state["costBaseline"] as? [String: Any], bl["totalCostUsd"] == nil {
        state.removeValue(forKey: "costBaseline")
    }
    return state
}

func writeState(_ state: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: state, options: []) else { return }
    let tmp = "\(statusDir)/.status.json.tmp"
    do { try data.write(to: URL(fileURLWithPath: tmp)) } catch { return }
    _ = rename(tmp, statusFile)
}

func readPersistMap() -> [String: [String: Any]] {
    guard let data = FileManager.default.contents(atPath: persistFile),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
        return [:]
    }
    return obj
}

func writePersistMap(_ map: [String: [String: Any]]) {
    let dir = (persistFile as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    guard let data = try? JSONSerialization.data(withJSONObject: map, options: []) else { return }
    try? data.write(to: URL(fileURLWithPath: persistFile), options: .atomic)
}

func readStdinJSON() -> [String: Any]? {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func nowMs() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

// MARK: - Tool detail extraction

func toolDetail(toolName: String, input: Any?) -> String? {
    guard let dict = input as? [String: Any] else { return nil }
    switch toolName {
    case "Bash":
        if let cmd = dict["command"] as? String, !cmd.isEmpty { return String(cmd.prefix(120)) }
    case "Read", "Write", "Edit":
        return dict["file_path"] as? String
    case "Grep":
        let p = (dict["pattern"] as? String) ?? ""
        let path = (dict["path"] as? String) ?? ""
        if !p.isEmpty { return "/\(p)/ \(path)".trimmingCharacters(in: .whitespaces) }
    case "Glob":
        return dict["pattern"] as? String
    case "Agent":
        return dict["description"] as? String
    case "WebFetch":
        return dict["url"] as? String
    case "WebSearch":
        return dict["query"] as? String
    case "TaskCreate":
        return dict["subject"] as? String
    case "TaskUpdate":
        if let s = dict["status"] as? String, let tid = dict["taskId"] as? String {
            return "#\(tid) -> \(s)"
        }
        return dict["subject"] as? String
    default:
        return nil
    }
    return nil
}

// MARK: - RTT tracking

func recordApiRTT(_ state: inout [String: Any], duration: Int, label: String) {
    var net = (state["network"] as? [String: Any]) ?? [:]
    net["lastToolMs"] = duration
    var recent = (net["recentToolMs"] as? [Int]) ?? []
    recent.append(duration)
    if recent.count > 10 { recent = Array(recent.suffix(10)) }
    net["recentToolMs"] = recent
    var entries = (net["recentTools"] as? [[String: Any]]) ?? []
    entries.append(["ms": duration, "tool": label])
    if entries.count > 10 { entries = Array(entries.suffix(10)) }
    net["recentTools"] = entries
    state["network"] = net
}

// MARK: - Hook subcommand

func runHook() {
    guard let event = readStdinJSON(),
          let hookEvent = event["hook_event_name"] as? String,
          !hookEvent.isEmpty else { exit(0) }

    let release = acquireLock()
    defer { release() }

    var state = readState()

    switch hookEvent {
    case "SessionStart":
        state["status"] = "idle"
        if let model = event["model"] { state["modelName"] = model }
        state["currentToolName"] = NSNull()
        state["toolDetail"] = NSNull()
        state["subagents"] = []
        state["tasks"] = []
        // Do NOT clear documents on SessionStart. Swift seeds this list from
        // the per-workingdir persist file before the hook runs, so docs
        // Claude wrote in prior sessions stay in the sidebar.
        if let ccId = event["session_id"] as? String, !ccId.isEmpty {
            state["claudeCodeSessionId"] = ccId
            // Seed displayed cost from last persisted value so the sidebar
            // shows something immediately on reopen until the first statusline
            // poll arrives with the authoritative cumulative total.
            let persist = readPersistMap()
            if let last = persist[ccId], last["totalCostUsd"] != nil {
                state["cost"] = last
            }
            state.removeValue(forKey: "costBaseline")
        }

    case "UserPromptSubmit":
        state["status"] = "thinking"
        state["currentToolName"] = NSNull()
        state["toolDetail"] = NSNull()
        state["activeTools"] = []
        state["needsInput"] = false
        let turns = (state["conversationTurns"] as? Int) ?? 0
        state["conversationTurns"] = turns + 1
        state["_apiSendMs"] = nowMs()
        // Jira ticket detection from prompt text
        if let prompt = event["prompt"] as? String,
           let cwd = event["cwd"] as? String,
           !cwd.isEmpty {
            let pattern = "(?i)(?:ticket|jira|issue|working on|this is for|for ticket)\\s*:?\\s*([A-Z][A-Z0-9]+-\\d+)"
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)),
               let range = Range(match.range(at: 1), in: prompt) {
                let ticket = String(prompt[range])
                let jiraPath = "\(cwd)/.jira-ticket"
                try? ticket.write(toFile: jiraPath, atomically: true, encoding: .utf8)
            }
        }

    case "PreToolUse":
        let toolName = (event["tool_name"] as? String) ?? ""
        let toolInput = event["tool_input"]
        let agentId = (event["agent_id"] as? String) ?? ""
        let hiddenAgents = readHiddenAgents()

        if !agentId.isEmpty && !hiddenAgents.contains(agentId) {
            // Subagent's tool use: update the subagent's currentTool
            var subs = (state["subagents"] as? [[String: Any]]) ?? []
            for i in 0..<subs.count {
                if let aid = subs[i]["id"] as? String, aid == agentId {
                    subs[i]["currentTool"] = toolName
                    if let d = toolDetail(toolName: toolName, input: toolInput) {
                        subs[i]["toolDetail"] = d
                    } else {
                        subs[i]["toolDetail"] = NSNull()
                    }
                    subs[i]["status"] = "streaming"
                }
            }
            state["subagents"] = subs
        } else {
            state["status"] = "tool_use"
            state["needsInput"] = false
            state["currentToolName"] = toolName
            if let d = toolDetail(toolName: toolName, input: toolInput) {
                state["toolDetail"] = d
            } else {
                state["toolDetail"] = NSNull()
            }
            var active = (state["activeTools"] as? [[String: Any]]) ?? []
            let toolId = (event["tool_use_id"] as? String) ?? ""
            if !toolId.isEmpty, !active.contains(where: { ($0["id"] as? String) == toolId }) {
                var entry: [String: Any] = ["id": toolId, "tool": toolName]
                entry["detail"] = toolDetail(toolName: toolName, input: toolInput) ?? ""
                active.append(entry)
            }
            state["activeTools"] = active

            if let sendMs = state["_apiSendMs"] as? Int {
                let duration = nowMs() - sendMs
                state.removeValue(forKey: "_apiSendMs")
                recordApiRTT(&state, duration: duration, label: toolName)
            }

            if toolName == "AskUserQuestion" {
                state["needsInput"] = true
            }

            // Track markdown documents Claude writes
            if toolName == "Write", let dict = toolInput as? [String: Any],
               let fp = dict["file_path"] as? String,
               (fp.lowercased().hasSuffix(".md") || fp.lowercased().hasSuffix(".markdown")),
               !fp.contains("/memory/") {
                var docs = (state["documents"] as? [String]) ?? []
                if !docs.contains(fp) {
                    docs.append(fp)
                    if docs.count > 5 { docs = Array(docs.suffix(5)) }
                    state["documents"] = docs
                }
            }
        }

        // Track task status changes via TaskUpdate
        if toolName == "TaskUpdate", let dict = toolInput as? [String: Any],
           let taskId = dict["taskId"] as? String {
            var tasks = (state["tasks"] as? [[String: Any]]) ?? []
            for i in 0..<tasks.count {
                guard (tasks[i]["id"] as? String) == taskId else { continue }
                if let newStatus = dict["status"] as? String { tasks[i]["status"] = newStatus }
                if let subject = dict["subject"] as? String { tasks[i]["subject"] = subject }
                var blockedBy = (tasks[i]["blockedBy"] as? [String]) ?? []
                if let added = dict["addBlockedBy"] as? [String] {
                    for bid in added where !blockedBy.contains(bid) { blockedBy.append(bid) }
                }
                if let addBlocks = dict["addBlocks"] as? [String] {
                    for bid in addBlocks {
                        for j in 0..<tasks.count where (tasks[j]["id"] as? String) == bid {
                            var ob = (tasks[j]["blockedBy"] as? [String]) ?? []
                            if !ob.contains(taskId) { ob.append(taskId) }
                            tasks[j]["blockedBy"] = ob
                        }
                    }
                }
                if !blockedBy.isEmpty { tasks[i]["blockedBy"] = blockedBy }
            }
            state["tasks"] = tasks
        }

    case "PostToolUse", "PostToolUseFailure":
        let agentId = (event["agent_id"] as? String) ?? ""
        if agentId.isEmpty {
            let toolId = (event["tool_use_id"] as? String) ?? ""
            var active = (state["activeTools"] as? [[String: Any]]) ?? []
            active.removeAll(where: { ($0["id"] as? String) == toolId })
            state["activeTools"] = active
            if active.isEmpty { state["status"] = "thinking" }
            state["_apiSendMs"] = nowMs()
        }

    case "Stop":
        if let sendMs = state["_apiSendMs"] as? Int {
            let duration = nowMs() - sendMs
            state.removeValue(forKey: "_apiSendMs")
            recordApiRTT(&state, duration: duration, label: "response")
        }
        state["status"] = "idle"
        state["currentToolName"] = NSNull()
        state["toolDetail"] = NSNull()
        state["activeTools"] = []

    case "SubagentStart":
        let agentId = (event["agent_id"] as? String) ?? ""
        let agentType = (event["agent_type"] as? String) ?? "agent"
        let hidden = readHiddenAgents()
        var subs = (state["subagents"] as? [[String: Any]]) ?? []
        if !agentId.isEmpty, !hidden.contains(agentId),
           !subs.contains(where: { ($0["id"] as? String) == agentId }) {
            var entry: [String: Any] = ["id": agentId, "name": agentType, "status": "streaming"]
            if let desc = event["description"] { entry["description"] = desc }
            subs.append(entry)
        }
        state["subagents"] = subs

    case "SubagentStop":
        let agentId = (event["agent_id"] as? String) ?? ""
        var subs = (state["subagents"] as? [[String: Any]]) ?? []
        subs.removeAll(where: { ($0["id"] as? String) == agentId })
        state["subagents"] = subs
        // Also remove from hidden-agents file if present
        let hiddenPath = "\(statusDir)/hidden-agents"
        if let existing = try? String(contentsOfFile: hiddenPath, encoding: .utf8) {
            var ids = Set(existing.split(whereSeparator: { $0.isWhitespace }).map(String.init))
            ids.remove(agentId)
            if ids.isEmpty { try? FileManager.default.removeItem(atPath: hiddenPath) }
            else { try? ids.joined(separator: " ").write(toFile: hiddenPath, atomically: true, encoding: .utf8) }
        }

    case "TaskCreated":
        let taskId = (event["task_id"] as? String) ?? ""
        let subject = (event["task_subject"] as? String) ?? ""
        var tasks = (state["tasks"] as? [[String: Any]]) ?? []
        if !taskId.isEmpty, !tasks.contains(where: { ($0["id"] as? String) == taskId }) {
            tasks.append(["id": taskId, "subject": subject, "status": "pending"])
        }
        state["tasks"] = tasks

    case "TaskCompleted":
        let taskId = (event["task_id"] as? String) ?? ""
        var tasks = (state["tasks"] as? [[String: Any]]) ?? []
        for i in 0..<tasks.count where (tasks[i]["id"] as? String) == taskId {
            tasks[i]["status"] = "completed"
        }
        state["tasks"] = tasks

    case "Notification":
        state["status"] = "idle"
        state["currentToolName"] = NSNull()
        state["toolDetail"] = NSNull()
        state["needsInput"] = true

    default:
        break
    }

    // Filter out hidden agents before writing
    let hidden = readHiddenAgents()
    if !hidden.isEmpty {
        if let subs = state["subagents"] as? [[String: Any]] {
            state["subagents"] = subs.filter { !hidden.contains(($0["id"] as? String) ?? "") }
        }
    }

    writeState(state)
}

func readHiddenAgents() -> Set<String> {
    let path = "\(statusDir)/hidden-agents"
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return Set(contents.split(whereSeparator: { $0.isWhitespace }).map(String.init))
}

// MARK: - Statusline subcommand

func runStatusLine() {
    guard let data = readStdinJSON() else { exit(0) }

    let release = acquireLock()
    defer { release() }

    var state = readState()

    // Context window
    if let cw = data["context_window"] as? [String: Any] {
        let cu = (cw["current_usage"] as? [String: Any]) ?? [:]
        var usage: [String: Any] = [
            "usedPercentage": cw["used_percentage"] ?? 0,
            "remainingPercentage": cw["remaining_percentage"] ?? 100,
            "contextWindowSize": cw["context_window_size"] ?? 200000,
            "totalInputTokens": cw["total_input_tokens"] ?? 0,
            "totalOutputTokens": cw["total_output_tokens"] ?? 0,
        ]
        usage["cacheReadTokens"] = cu["cache_read_input_tokens"] ?? NSNull()
        usage["cacheCreationTokens"] = cu["cache_creation_input_tokens"] ?? NSNull()
        state["contextUsage"] = usage
    }

    // Cost: Claude Code's statusline already reports cumulative session totals
    // across --continue, so use them directly. The SessionStart hook seeds
    // state["cost"] from the persist file as a placeholder until the first
    // real poll arrives.
    if let cost = data["cost"] as? [String: Any] {
        let repUsd = (cost["total_cost_usd"] as? NSNumber)?.doubleValue ?? 0
        let repDur = (cost["total_duration_ms"] as? NSNumber)?.intValue ?? 0
        let repApiDur = (cost["total_api_duration_ms"] as? NSNumber)?.intValue ?? 0
        let repAdd = (cost["total_lines_added"] as? NSNumber)?.intValue ?? 0
        let repRem = (cost["total_lines_removed"] as? NSNumber)?.intValue ?? 0
        let totalCost: [String: Any] = [
            "totalCostUsd": repUsd,
            "totalDurationMs": repDur,
            "totalApiDurationMs": repApiDur,
            "totalLinesAdded": repAdd,
            "totalLinesRemoved": repRem,
        ]
        state["cost"] = totalCost

        // Network metrics
        let turns = (state["conversationTurns"] as? Int) ?? 0
        if turns > 0 {
            var net = (state["network"] as? [String: Any]) ?? [:]
            let apiMs = (cost["total_api_duration_ms"] as? NSNumber)?.intValue ?? 0
            let totalMs = (cost["total_duration_ms"] as? NSNumber)?.intValue ?? 0
            net["avgApiMsPerTurn"] = apiMs / turns
            if totalMs > 0 { net["apiTimePercent"] = apiMs * 100 / totalMs }
            state["network"] = net
        }

        // Persist cumulative total keyed by Claude Code session_id
        let ccId = (data["session_id"] as? String) ?? (state["claudeCodeSessionId"] as? String) ?? ""
        if !ccId.isEmpty {
            var map = readPersistMap()
            map[ccId] = totalCost
            writePersistMap(map)
        }
    }

    // Model info
    if let model = data["model"] as? [String: Any] {
        let display = (model["display_name"] as? String) ?? ""
        let mid = (model["id"] as? String) ?? ""
        if !display.isEmpty || !mid.isEmpty {
            state["modelName"] = display.isEmpty ? mid : display
        }
    }

    // Session name (don't overwrite user renames)
    if let sname = data["session_name"] as? String,
       !sname.isEmpty,
       !((state["sessionNameOverride"] as? Bool) ?? false) {
        state["sessionName"] = sname
    }

    writeState(state)

    // Output a compact status line to stdout for the terminal. Claude Code
    // shows this below the prompt. Keep short.
    var parts: [String] = []
    if let model = state["modelName"] as? String, !model.isEmpty { parts.append(model) }
    if let cost = state["cost"] as? [String: Any],
       let usd = (cost["totalCostUsd"] as? NSNumber)?.doubleValue, usd > 0 {
        parts.append(String(format: "$%.2f", max(0, usd)))
    }
    if let ctx = state["contextUsage"] as? [String: Any],
       let pct = (ctx["usedPercentage"] as? NSNumber)?.intValue, pct > 0 {
        parts.append("\(pct)%")
    }
    print(parts.joined(separator: "  "))
}
