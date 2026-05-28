import Foundation

// claude-terminal-hook: embedded helper binary invoked by Claude Code hooks
// (subcommand `hook`) and statusLine (subcommand `statusline`). Reads JSON
// from stdin, updates ~/.claude-terminal/sessions/<id>/status.json, and
// writes a compact status line to stdout for the `statusline` subcommand.

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
let hookLogFile = "\(home)/.claude-terminal/hook.log"

/// Append a breadcrumb to both stderr AND ~/.claude-terminal/hook.log.
/// Flushing to a file synced per call means the trail survives SIGKILL
/// / SIGSEGV — useful for diagnosing "non-blocking status code, no stderr"
/// errors where Claude Code's stderr capture is unreliable.
func hookLog(_ message: String) {
    let ts: String = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }()
    let line = "\(ts) [\(sessionId.prefix(8))] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    FileHandle.standardError.write(data)
    // O_APPEND + fsync so the line hits disk even if the process is
    // killed immediately after this call. Single system-call append is
    // atomic on POSIX, so concurrent hooks won't interleave.
    let fd = open(hookLogFile, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    guard fd >= 0 else { return }
    _ = data.withUnsafeBytes { buf in
        write(fd, buf.baseAddress, buf.count)
    }
    fsync(fd)
    close(fd)
}

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
    // Strip the legacy costBaseline field that older versions wrote — cost
    // math is now done entirely on Claude Code's reported totals.
    state.removeValue(forKey: "costBaseline")
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
        if let cmd = dict["command"] as? String, !cmd.isEmpty { return String(cmd.prefix(500)) }
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
    let apiTotal = ((net["apiMsTotal"] as? NSNumber)?.intValue ?? 0) + duration
    net["apiMsTotal"] = apiTotal
    state["network"] = net
}

func recordToolDuration(_ state: inout [String: Any], duration: Int) {
    var net = (state["network"] as? [String: Any]) ?? [:]
    let toolTotal = ((net["toolMsTotal"] as? NSNumber)?.intValue ?? 0) + duration
    net["toolMsTotal"] = toolTotal
    state["network"] = net
}

// MARK: - Hook subcommand

func runHook() {
    guard let event = readStdinJSON(),
          let hookEvent = event["hook_event_name"] as? String,
          !hookEvent.isEmpty else { exit(0) }

    let hookStarted = Date()
    let toolName = (event["tool_name"] as? String) ?? ""
    let hookTag = "\(hookEvent)\(toolName.isEmpty ? "" : ":\(toolName)")"
    // Breadcrumb at hook entry. If we ever see `enter` without the
    // matching `done`, the hook died mid-flight (crash / timeout). Logs
    // persist to ~/.claude-terminal/hook.log via fsync so the trail
    // survives SIGKILL.
    hookLog("enter \(hookTag)")
    defer {
        let elapsedMs = Int(Date().timeIntervalSince(hookStarted) * 1000)
        hookLog("done  \(hookTag) \(elapsedMs)ms")
    }

    // Stage breadcrumbs — narrow down which phase is hanging when the
    // hook times out. The last `stage` line before SIGKILL identifies
    // the exact call site that's blocking.
    hookLog("stage lock.acquire")
    let release = acquireLock()
    hookLog("stage lock.acquired")
    defer { release() }

    hookLog("stage state.read")
    var state = readState()
    hookLog("stage state.loaded")

    // Every hook event carries the current permission_mode
    // ("default" | "plan" | "acceptEdits" | "bypassPermissions" | ...).
    // Capture it so the sidebar can surface plan / YOLO mode.
    if let mode = event["permission_mode"] as? String, !mode.isEmpty {
        state["permissionMode"] = mode
    }

    switch hookEvent {
    case "SessionStart":             handleSessionStart(&state, event: event)
    case "UserPromptSubmit":         handleUserPromptSubmit(&state, event: event)
    case "PreToolUse":               handlePreToolUse(&state, event: event)
    case "PostToolUse",
         "PostToolUseFailure":       handlePostToolUse(&state, event: event)
    case "Stop":                     handleStop(&state)
    case "SubagentStart":            handleSubagentStart(&state, event: event)
    case "SubagentStop":             handleSubagentStop(&state, event: event)
    case "TaskCreated":              handleTaskCreated(&state, event: event)
    case "TaskCompleted":            handleTaskCompleted(&state, event: event)
    case "Notification":             handleNotification(&state)
    default:                         break
    }

    // Filter out hidden agents before writing
    let hidden = readHiddenAgents()
    if !hidden.isEmpty {
        if let subs = state["subagents"] as? [[String: Any]] {
            state["subagents"] = subs.filter { !hidden.contains(($0["id"] as? String) ?? "") }
        }
    }

    hookLog("stage state.write")
    writeState(state)
    hookLog("stage state.written")
}

// MARK: - Per-event handlers

func handleSessionStart(_ state: inout [String: Any], event: [String: Any]) {
    state["status"] = "idle"
    if let model = event["model"] { state["modelName"] = model }
    state["currentToolName"] = NSNull()
    state["toolDetail"] = NSNull()
    state["activeTools"] = []
    state["subagents"] = []
    state["tasks"] = []
    // Reset cumulative-per-session counters. /clear creates a fresh
    // session_id; cost, turn count, and network totals all belong to the
    // prior session and must not bleed across. Resume hydrates these
    // again from the persist map below when the id matches.
    state.removeValue(forKey: "cost")
    state.removeValue(forKey: "network")
    state["conversationTurns"] = 0
    // Do NOT clear documents on SessionStart. Swift seeds this list from
    // the per-workingdir persist file before the hook runs, so docs
    // Claude wrote in prior sessions stay in the sidebar.
    if let ccId = event["session_id"] as? String, !ccId.isEmpty {
        state["claudeCodeSessionId"] = ccId
        // Seed displayed cost from last persisted value so the sidebar
        // shows something immediately on reopen until the first statusline
        // poll arrives with the authoritative cumulative total. Only
        // matches when Claude Code is resuming the same session_id —
        // /clear's brand-new id won't be in the map.
        let persist = readPersistMap()
        if let last = persist[ccId], last["totalCostUsd"] != nil {
            state["cost"] = last
        }
    }
}

func handleUserPromptSubmit(_ state: inout [String: Any], event: [String: Any]) {
    state["status"] = "thinking"
    state["currentToolName"] = NSNull()
    state["toolDetail"] = NSNull()
    state["activeTools"] = []
    state["needsInput"] = false
    let turns = (state["conversationTurns"] as? Int) ?? 0
    state["conversationTurns"] = turns + 1
    state["_apiSendMs"] = nowMs()
    detectJiraTicketInPrompt(event: event)
}

/// Scan the prompt for an inline Jira-ticket reference and persist it to
/// `<cwd>/.jira-ticket` so the sidebar can pick it up. Picks up phrasings
/// like "ticket: ABC-123", "jira ABC-123", "this is for ABC-123", etc.
private func detectJiraTicketInPrompt(event: [String: Any]) {
    guard let prompt = event["prompt"] as? String,
          let cwd = event["cwd"] as? String,
          !cwd.isEmpty else { return }
    let pattern = "(?i)(?:ticket|jira|issue|working on|this is for|for ticket)\\s*:?\\s*([A-Z][A-Z0-9]+-\\d+)"
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)),
          let range = Range(match.range(at: 1), in: prompt) else { return }
    let ticket = String(prompt[range])
    try? ticket.write(toFile: "\(cwd)/.jira-ticket", atomically: true, encoding: .utf8)
}

func handlePreToolUse(_ state: inout [String: Any], event: [String: Any]) {
    let toolName = (event["tool_name"] as? String) ?? ""
    let toolInput = event["tool_input"]
    let agentId = (event["agent_id"] as? String) ?? ""
    let hiddenAgents = readHiddenAgents()

    if !agentId.isEmpty && !hiddenAgents.contains(agentId) {
        applyPreToolUseToSubagent(&state, agentId: agentId, toolName: toolName, toolInput: toolInput)
    } else {
        applyPreToolUseToHost(&state, event: event, toolName: toolName, toolInput: toolInput)
        captureViewableDocumentPath(&state, toolInput: toolInput)
    }

    // Track task status changes via TaskUpdate
    if toolName == "TaskUpdate", let dict = toolInput as? [String: Any],
       let taskId = dict["taskId"] as? String {
        applyTaskUpdate(&state, taskId: taskId, dict: dict)
    }
}

private func applyPreToolUseToSubagent(
    _ state: inout [String: Any],
    agentId: String,
    toolName: String,
    toolInput: Any?
) {
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
}

private func applyPreToolUseToHost(
    _ state: inout [String: Any],
    event: [String: Any],
    toolName: String,
    toolInput: Any?
) {
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

    // Stash the PreToolUse timestamp so PostToolUse can compute how
    // long the local tool actually took.
    if !toolId.isEmpty {
        var startMap = (state["_toolStartMs"] as? [String: Int]) ?? [:]
        startMap[toolId] = nowMs()
        state["_toolStartMs"] = startMap
    }

    if toolName == "AskUserQuestion" {
        state["needsInput"] = true
    }
}

/// Track any viewable file Claude touches — markdown and common
/// raster/vector image formats. The Swift sidebar renders these
/// inline (markdown via WebKit, images via NSImage), so capturing
/// them here makes them clickable in the Documents card.
private func captureViewableDocumentPath(_ state: inout [String: Any], toolInput: Any?) {
    guard let dict = toolInput as? [String: Any] else { return }
    let candidate = (dict["file_path"] as? String) ?? (dict["notebook_path"] as? String)
    guard let fp = candidate else { return }
    let lower = fp.lowercased()
    let viewableExtensions = [
        ".md", ".markdown", ".mdown",
        ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".tiff", ".tif",
        ".webp", ".heic", ".heif", ".svg", ".ico", ".avif",
    ]
    guard viewableExtensions.contains(where: { lower.hasSuffix($0) }),
          !fp.contains("/memory/") else { return }
    var docs = (state["documents"] as? [String]) ?? []
    if !docs.contains(fp) {
        docs.append(fp)
        state["documents"] = docs
    }
}

private func applyTaskUpdate(_ state: inout [String: Any], taskId: String, dict: [String: Any]) {
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

func handlePostToolUse(_ state: inout [String: Any], event: [String: Any]) {
    let agentId = (event["agent_id"] as? String) ?? ""
    guard agentId.isEmpty else { return }
    let toolId = (event["tool_use_id"] as? String) ?? ""
    var active = (state["activeTools"] as? [[String: Any]]) ?? []
    active.removeAll(where: { ($0["id"] as? String) == toolId })
    state["activeTools"] = active
    if active.isEmpty { state["status"] = "thinking" }

    // Compute how long this tool took locally and add to the
    // cumulative tool-time total for the session.
    if !toolId.isEmpty,
       var startMap = state["_toolStartMs"] as? [String: Int],
       let startMs = startMap[toolId] {
        let duration = nowMs() - startMs
        if duration >= 0 { recordToolDuration(&state, duration: duration) }
        startMap.removeValue(forKey: toolId)
        state["_toolStartMs"] = startMap
    }

    // Intentionally no Bash-command image-path extraction here.
    // Three implementations (dir walk, regex, tokenize+fileExists)
    // all hung PostToolUse:Bash in practice — the common thread is
    // that blocking filesystem calls from a short-lived CLI
    // process have no reliable async escape. Read/Write/Edit/
    // NotebookEdit already surface paths via PreToolUse file_path,
    // which covers the common cases without any scanning risk.

    state["_apiSendMs"] = nowMs()
}

func handleStop(_ state: inout [String: Any]) {
    if let sendMs = state["_apiSendMs"] as? Int {
        let duration = nowMs() - sendMs
        state.removeValue(forKey: "_apiSendMs")
        recordApiRTT(&state, duration: duration, label: "response")
    }
    state["status"] = "idle"
    state["currentToolName"] = NSNull()
    state["toolDetail"] = NSNull()
    state["activeTools"] = []
}

func handleSubagentStart(_ state: inout [String: Any], event: [String: Any]) {
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
}

func handleSubagentStop(_ state: inout [String: Any], event: [String: Any]) {
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
}

func handleTaskCreated(_ state: inout [String: Any], event: [String: Any]) {
    let taskId = (event["task_id"] as? String) ?? ""
    let subject = (event["task_subject"] as? String) ?? ""
    var tasks = (state["tasks"] as? [[String: Any]]) ?? []
    if !taskId.isEmpty, !tasks.contains(where: { ($0["id"] as? String) == taskId }) {
        tasks.append(["id": taskId, "subject": subject, "status": "pending"])
    }
    state["tasks"] = tasks
}

func handleTaskCompleted(_ state: inout [String: Any], event: [String: Any]) {
    let taskId = (event["task_id"] as? String) ?? ""
    var tasks = (state["tasks"] as? [[String: Any]]) ?? []
    for i in 0..<tasks.count where (tasks[i]["id"] as? String) == taskId {
        tasks[i]["status"] = "completed"
    }
    state["tasks"] = tasks
}

func handleNotification(_ state: inout [String: Any]) {
    state["status"] = "idle"
    state["currentToolName"] = NSNull()
    state["toolDetail"] = NSNull()
    state["needsInput"] = true
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

    // Permission mode (PLAN/YOLO badge) is captured exclusively from hook
    // events — Claude Code doesn't expose it in the statusline payload and
    // doesn't fire any hook on Shift+Tab while idle, so the badge can only
    // refresh when the user submits a prompt. If Claude Code ever starts
    // including permission_mode here, this one line will pick it up.
    if let mode = data["permission_mode"] as? String, !mode.isEmpty {
        state["permissionMode"] = mode
    }

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

    // Pull request: Claude Code emits a `pr` block on the statusline payload
    // when an open PR exists for the current branch. Drop the field once the
    // PR closes/merges so the sidebar reflects current branch state.
    if let pr = data["pr"] as? [String: Any],
       let num = (pr["number"] as? NSNumber)?.intValue {
        var info: [String: Any] = ["number": num]
        if let url = pr["url"] as? String, !url.isEmpty { info["url"] = url }
        if let rs = pr["review_state"] as? String, !rs.isEmpty { info["reviewState"] = rs }
        state["pullRequest"] = info
    } else {
        state.removeValue(forKey: "pullRequest")
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
