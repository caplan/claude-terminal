import Foundation

enum HookInstaller {
    private static let hookDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude-terminal/hooks")
    private static let hookPath = hookDir.appendingPathComponent("update-status.sh")
    private static let statusLinePath = hookDir.appendingPathComponent("statusline.sh")
    private static let claudeSettingsPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")

    static func installIfNeeded() {
        installHookScript()
        installStatusLineScript()
        configureClaudeSettings()
    }

    // MARK: - Hook Script

    private static func installHookScript() {
        let fm = FileManager.default
        try? fm.createDirectory(at: hookDir, withIntermediateDirectories: true)

        let currentVersion = hookScriptVersion(at: hookPath)
        let latestVersion = "31"

        if currentVersion == latestVersion { return }

        try? hookScript.write(to: hookPath, atomically: true, encoding: .utf8)

        var attrs = [FileAttributeKey: Any]()
        attrs[.posixPermissions] = 0o755
        try? fm.setAttributes(attrs, ofItemAtPath: hookPath.path)

        print("[claude-terminal] Installed hook script v\(latestVersion)")
    }

    private static func hookScriptVersion(at url: URL) -> String? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in contents.components(separatedBy: "\n") {
            if line.hasPrefix("# VERSION=") {
                return String(line.dropFirst("# VERSION=".count))
            }
        }
        return nil
    }

    private static func installStatusLineScript() {
        let fm = FileManager.default
        try? fm.createDirectory(at: hookDir, withIntermediateDirectories: true)

        let currentVersion = hookScriptVersion(at: statusLinePath)
        let latestVersion = "10"

        if currentVersion == latestVersion { return }

        try? statusLineScript.write(to: statusLinePath, atomically: true, encoding: .utf8)

        var attrs = [FileAttributeKey: Any]()
        attrs[.posixPermissions] = 0o755
        try? fm.setAttributes(attrs, ofItemAtPath: statusLinePath.path)

        print("[claude-terminal] Installed status line script v\(latestVersion)")
    }

    // MARK: - Claude Settings

    private static func configureClaudeSettings() {
        let fm = FileManager.default
        let settingsPath = claudeSettingsPath.path

        var settings: [String: Any] = [:]
        if fm.fileExists(atPath: settingsPath),
           let data = fm.contents(atPath: settingsPath),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = parsed
        }

        let hookCommand = hookPath.path
        let desiredHooks = buildDesiredHooks(command: hookCommand)

        var existingHooks = settings["hooks"] as? [String: Any] ?? [:]
        var changed = false

        for (eventName, hookConfigs) in desiredHooks {
            let existing = existingHooks[eventName] as? [[String: Any]] ?? []
            let alreadyConfigured = existing.contains { entry in
                if let hooks = entry["hooks"] as? [[String: Any]] {
                    return hooks.contains { ($0["command"] as? String)?.contains("claude-terminal") == true }
                }
                if let cmd = entry["command"] as? String {
                    return cmd.contains("claude-terminal")
                }
                return false
            }
            if !alreadyConfigured {
                var updated = existing
                updated.append(contentsOf: hookConfigs)
                existingHooks[eventName] = updated
                changed = true
            }
        }

        // Configure status line
        let existingStatusLine = settings["statusLine"] as? [String: Any]
        let statusLineCommand = (existingStatusLine?["command"] as? String) ?? ""
        if !statusLineCommand.contains("claude-terminal") {
            settings["statusLine"] = [
                "type": "command",
                "command": statusLinePath.path,
                "refreshInterval": 3
            ] as [String: Any]
            changed = true
        }

        if changed {
            settings["hooks"] = existingHooks
            if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
                let dir = (settingsPath as NSString).deletingLastPathComponent
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try? data.write(to: claudeSettingsPath, options: .atomic)
                print("[claude-terminal] Configured Claude Code hooks")
            }
        }
    }

    private static func buildDesiredHooks(command: String) -> [String: [[String: Any]]] {
        let toolHookEntry: [String: Any] = [
            "matcher": "",
            "hooks": [
                ["type": "command", "command": command, "timeout": 5] as [String: Any]
            ]
        ]

        let simpleHookEntry: [String: Any] = [
            "matcher": "",
            "hooks": [
                ["type": "command", "command": command, "timeout": 5] as [String: Any]
            ]
        ]

        return [
            "SessionStart": [simpleHookEntry],
            "UserPromptSubmit": [simpleHookEntry],
            "PreToolUse": [toolHookEntry],
            "PostToolUse": [toolHookEntry],
            "Stop": [simpleHookEntry],
            "SubagentStart": [simpleHookEntry],
            "SubagentStop": [simpleHookEntry],
            "TaskCreated": [simpleHookEntry],
            "TaskCompleted": [simpleHookEntry],
            "Notification": [simpleHookEntry],
        ]
    }

    // MARK: - Hook Script Content

    private static let hookScript = """
    #!/usr/bin/env python3
    # VERSION=31
    # Claude Terminal status hook — writes session state to ~/.claude-terminal/sessions/<id>/status.json
    # Called by Claude Code hooks on various events. No-op if CLAUDE_TERMINAL_SESSION_ID is unset.

    import json, os, sys, tempfile, time, fcntl

    session_id = os.environ.get("CLAUDE_TERMINAL_SESSION_ID", "")
    if not session_id:
        sys.exit(0)

    status_dir = os.path.expanduser(f"~/.claude-terminal/sessions/{session_id}")
    status_file = os.path.join(status_dir, "status.json")
    lock_file = os.path.join(status_dir, ".status.lock")
    os.makedirs(status_dir, exist_ok=True)

    try:
        event = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    hook_event = event.get("hook_event_name", "")
    if not hook_event:
        sys.exit(0)

    # Exclusive lock for the read-modify-write cycle so this hook can't
    # interleave with the app's writeState (e.g. the cost reset button) or
    # the statusline script.
    _lock_fd = open(lock_file, "w")
    fcntl.flock(_lock_fd.fileno(), fcntl.LOCK_EX)

    # Load existing state
    try:
        with open(status_file) as f:
            state = json.load(f)
    except Exception:
        state = {"status": "disconnected", "subagents": [], "tasks": []}

    def tool_detail_from_input(tool_name, tool_input):
        if not tool_input or not isinstance(tool_input, dict):
            return None
        if tool_name == "Bash":
            cmd = tool_input.get("command", "")
            return cmd[:120] if cmd else None
        if tool_name in ("Read", "Write"):
            return tool_input.get("file_path")
        if tool_name == "Edit":
            return tool_input.get("file_path")
        if tool_name == "Grep":
            p = tool_input.get("pattern", "")
            path = tool_input.get("path", "")
            return f"/{p}/ {path}".strip() if p else None
        if tool_name == "Glob":
            return tool_input.get("pattern")
        if tool_name == "Agent":
            return tool_input.get("description")
        if tool_name == "WebFetch":
            return tool_input.get("url")
        if tool_name == "WebSearch":
            return tool_input.get("query")
        if tool_name == "TaskCreate":
            return tool_input.get("subject")
        if tool_name == "TaskUpdate":
            s = tool_input.get("status")
            subj = tool_input.get("subject", "")
            tid = tool_input.get("taskId", "")
            return f"#{tid} -> {s}" if s else subj or None
        return None

    def _record_api_rtt(state, duration, label):
        net = state.get("network", {})
        net["lastToolMs"] = duration
        recent = net.get("recentToolMs", [])
        recent.append(duration)
        net["recentToolMs"] = recent[-10:]
        entries = net.get("recentTools", [])
        entries.append({"ms": duration, "tool": label})
        net["recentTools"] = entries[-10:]
        state["network"] = net

    if hook_event == "SessionStart":
        state["status"] = "idle"
        state["modelName"] = event.get("model")
        state["currentToolName"] = None
        state["toolDetail"] = None
        state["subagents"] = []
        state["tasks"] = []
        state["documents"] = []
        # Capture cost baseline from persistent map (keyed by Claude Code session_id).
        # Claude Code's statusline cost restarts at 0 on --continue; we add the
        # previous total as a baseline so the UI shows cumulative cost across reopens.
        cc_session_id = event.get("session_id", "")
        if cc_session_id:
            state["claudeCodeSessionId"] = cc_session_id
            persist_path = os.path.expanduser("~/.claude-terminal/cost-by-session.json")
            _baseline = None
            try:
                with open(persist_path) as f:
                    _persist = json.load(f)
                _baseline = _persist.get(cc_session_id)
            except Exception:
                _baseline = None
            # Only set costBaseline if we have a real, fully-populated CostInfo — the
            # Swift side decodes this as a CostInfo with non-optional fields, so an
            # empty dict would fail decoding and disconnect the sidebar.
            if isinstance(_baseline, dict) and "totalCostUsd" in _baseline:
                state["costBaseline"] = _baseline
                # Seed displayed cost from baseline so the sidebar shows the last known
                # total immediately on reopen, without waiting for the first statusline poll.
                state["cost"] = dict(_baseline)
            else:
                # Ensure no stale empty dict is left behind
                state.pop("costBaseline", None)

    elif hook_event == "UserPromptSubmit":
        state["status"] = "thinking"
        state["currentToolName"] = None
        state["toolDetail"] = None
        state["activeTools"] = []
        # Don't clear subagents here — background agents outlive the parent's turn
        # and are removed by their own SubagentStop. SessionStart is the cold reset.
        state["needsInput"] = False
        state["conversationTurns"] = state.get("conversationTurns", 0) + 1
        state["_apiSendMs"] = int(time.time() * 1000)

        import re
        prompt = event.get("prompt", "")
        jira_intent = re.search(
            r"(?:ticket|jira|issue|working on|this is for|for ticket)\\s*:?\\s*([A-Z][A-Z0-9]+-\\d+)",
            prompt, re.IGNORECASE
        )
        if jira_intent:
            cwd = event.get("cwd", "")
            if cwd:
                try:
                    with open(os.path.join(cwd, ".jira-ticket"), "w") as tf:
                        tf.write(jira_intent.group(1))
                except Exception:
                    pass

    elif hook_event == "PreToolUse":
        tool_name = event.get("tool_name", "")
        tool_input = event.get("tool_input", {})
        agent_id = event.get("agent_id", "")

        # If this is a subagent tool use, update the subagent's currentTool
        hidden_file = os.path.join(status_dir, "hidden-agents")
        try:
            _hidden = set(open(hidden_file).read().strip().split())
        except Exception:
            _hidden = set()
        if agent_id and agent_id not in _hidden:
            for a in state.get("subagents", []):
                if a["id"] == agent_id:
                    a["currentTool"] = tool_name
                    a["toolDetail"] = tool_detail_from_input(tool_name, tool_input)
                    a["status"] = "streaming"
        else:
            state["status"] = "tool_use"
            state["needsInput"] = False
            state["currentToolName"] = tool_name
            state["toolDetail"] = tool_detail_from_input(tool_name, tool_input)
            # Accumulate parallel tool calls
            active = state.get("activeTools", [])
            tool_id = event.get("tool_use_id", "")
            entry = {"id": tool_id, "tool": tool_name, "detail": tool_detail_from_input(tool_name, tool_input) or ""}
            if tool_id and not any(t["id"] == tool_id for t in active):
                active.append(entry)
            state["activeTools"] = active

            # Record API round trip: time from last send to this response
            api_start = state.pop("_apiSendMs", None)
            if api_start:
                duration = int(time.time() * 1000) - api_start
                _record_api_rtt(state, duration, tool_name)

            # AskUserQuestion means Claude needs user input
            if tool_name == "AskUserQuestion":
                state["needsInput"] = True

            # Track written markdown files for the documents list
            if tool_name == "Write":
                fp = tool_input.get("file_path", "") if isinstance(tool_input, dict) else ""
                if fp and fp.lower().endswith((".md", ".markdown")) and "/memory/" not in fp:
                    docs = state.get("documents", [])
                    if fp not in docs:
                        docs.append(fp)
                    state["documents"] = docs[-5:]

        # Track task status changes via TaskUpdate tool
        if tool_name == "TaskUpdate" and isinstance(tool_input, dict):
            task_id = tool_input.get("taskId")
            if task_id:
                for t in state.get("tasks", []):
                    if t["id"] == task_id:
                        new_status = tool_input.get("status")
                        if new_status:
                            t["status"] = new_status
                        if "subject" in tool_input:
                            t["subject"] = tool_input["subject"]
                        blocked_by = t.get("blockedBy", [])
                        for bid in tool_input.get("addBlockedBy", []):
                            if bid not in blocked_by:
                                blocked_by.append(bid)
                        for bid in tool_input.get("addBlocks", []):
                            for other in state.get("tasks", []):
                                if other["id"] == bid:
                                    ob = other.get("blockedBy", [])
                                    if task_id not in ob:
                                        ob.append(task_id)
                                    other["blockedBy"] = ob
                        if blocked_by:
                            t["blockedBy"] = blocked_by

    elif hook_event in ("PostToolUse", "PostToolUseFailure"):
        agent_id = event.get("agent_id", "")
        if not agent_id:
            tool_id = event.get("tool_use_id", "")
            active = state.get("activeTools", [])
            active = [t for t in active if t.get("id") != tool_id]
            state["activeTools"] = active
            if not active:
                state["status"] = "thinking"
            # Tool result is being sent back to the API — start timing the next round trip
            state["_apiSendMs"] = int(time.time() * 1000)

    elif hook_event == "Stop":
        # Record final API round trip
        api_start = state.pop("_apiSendMs", None)
        if api_start:
            duration = int(time.time() * 1000) - api_start
            _record_api_rtt(state, duration, "response")
        state["status"] = "idle"
        state["currentToolName"] = None
        state["toolDetail"] = None
        state["activeTools"] = []
        # Don't clear subagents here — background agents can outlive Stop.
        # They're removed by their own SubagentStop event.

    elif hook_event == "SubagentStart":
        agent_id = event.get("agent_id", "")
        agent_type = event.get("agent_type", "")
        subs = state.get("subagents", [])
        hidden_file = os.path.join(status_dir, "hidden-agents")
        try:
            hidden = set(open(hidden_file).read().strip().split())
        except Exception:
            hidden = set()
        if agent_id and agent_id not in hidden and not any(a["id"] == agent_id for a in subs):
            subs.append({
                "id": agent_id,
                "name": agent_type or "agent",
                "status": "streaming",
                "description": event.get("description"),
            })
        state["subagents"] = subs

    elif hook_event == "SubagentStop":
        agent_id = event.get("agent_id", "")
        state["subagents"] = [a for a in state.get("subagents", []) if a.get("id") != agent_id]
        hidden_file = os.path.join(status_dir, "hidden-agents")
        try:
            lines = set(open(hidden_file).read().strip().split())
            lines.discard(agent_id)
            if lines:
                open(hidden_file, "w").write(" ".join(lines))
            else:
                os.unlink(hidden_file)
        except Exception:
            pass

    elif hook_event == "TaskCreated":
        task_id = event.get("task_id", "")
        subject = event.get("task_subject", "")
        tasks = state.get("tasks", [])
        if task_id and not any(t["id"] == task_id for t in tasks):
            tasks.append({"id": task_id, "subject": subject, "status": "pending"})
        state["tasks"] = tasks

    elif hook_event == "TaskCompleted":
        task_id = event.get("task_id", "")
        for t in state.get("tasks", []):
            if t["id"] == task_id:
                t["status"] = "completed"

    elif hook_event == "Notification":
        state["status"] = "idle"
        state["currentToolName"] = None
        state["toolDetail"] = None
        state["needsInput"] = True

    # Filter out hidden agents before writing
    _hf = os.path.join(status_dir, "hidden-agents")
    try:
        _ha = set(open(_hf).read().strip().split())
        if _ha:
            state["subagents"] = [a for a in state.get("subagents", []) if a.get("id") not in _ha]
    except Exception:
        pass

    # Atomic write via temp file + rename
    fd, tmp = tempfile.mkstemp(dir=status_dir, suffix=".json")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(state, f)
        os.replace(tmp, status_file)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
    """

    // MARK: - Status Line Script Content

    private static let statusLineScript = """
    #!/usr/bin/env python3
    # VERSION=10
    # Claude Terminal status line — merges context_window and cost into status.json
    # Also outputs a compact status line for the terminal.

    import json, os, sys, tempfile, fcntl

    session_id = os.environ.get("CLAUDE_TERMINAL_SESSION_ID", "")
    if not session_id:
        # Not running in claude-terminal, just exit
        sys.exit(0)

    status_dir = os.path.expanduser(f"~/.claude-terminal/sessions/{session_id}")
    status_file = os.path.join(status_dir, "status.json")
    lock_file = os.path.join(status_dir, ".status.lock")
    os.makedirs(status_dir, exist_ok=True)

    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    # Hold an exclusive lock on the status file for the entire read-modify-write
    # cycle so we can't interleave with the app's writes (e.g. the cost reset
    # button). The lock file is separate from status.json itself because we
    # update status.json via atomic rename.
    _lock_fd = open(lock_file, "w")
    fcntl.flock(_lock_fd.fileno(), fcntl.LOCK_EX)

    # Load existing state (written by hooks)
    try:
        with open(status_file) as f:
            state = json.load(f)
    except Exception:
        state = {"status": "disconnected", "subagents": [], "tasks": []}

    # Remove invalid costBaseline (empty dict breaks Swift's CostInfo decoding)
    _bl = state.get("costBaseline")
    if isinstance(_bl, dict) and "totalCostUsd" not in _bl:
        del state["costBaseline"]

    # Merge context window data
    cw = data.get("context_window", {})
    if cw:
        cu = cw.get("current_usage", {})
        state["contextUsage"] = {
            "usedPercentage": cw.get("used_percentage", 0),
            "remainingPercentage": cw.get("remaining_percentage", 100),
            "contextWindowSize": cw.get("context_window_size", 200000),
            "totalInputTokens": cw.get("total_input_tokens", 0),
            "totalOutputTokens": cw.get("total_output_tokens", 0),
            "cacheReadTokens": cu.get("cache_read_input_tokens"),
            "cacheCreationTokens": cu.get("cache_creation_input_tokens"),
        }

    # Merge cost data. Claude Code reports the current process's cost; we add the
    # baseline captured at SessionStart (from a previous --continue'd session) so
    # the UI shows cumulative cost across reopens. Also persist the running total
    # keyed by Claude Code session_id so the next reopen can restore it.
    cost = data.get("cost", {})
    if cost:
        baseline = state.get("costBaseline") or {}
        state["cost"] = {
            "totalCostUsd": baseline.get("totalCostUsd", 0) + cost.get("total_cost_usd", 0),
            "totalDurationMs": baseline.get("totalDurationMs", 0) + cost.get("total_duration_ms", 0),
            "totalApiDurationMs": baseline.get("totalApiDurationMs", 0) + cost.get("total_api_duration_ms", 0),
            "totalLinesAdded": baseline.get("totalLinesAdded", 0) + cost.get("total_lines_added", 0),
            "totalLinesRemoved": baseline.get("totalLinesRemoved", 0) + cost.get("total_lines_removed", 0),
        }

    # Derive network metrics from cost and turn count
    turns = state.get("conversationTurns", 0)
    if cost and turns > 0:
        net = state.get("network", {})
        api_ms = cost.get("total_api_duration_ms", 0)
        total_ms = cost.get("total_duration_ms", 0)
        net["avgApiMsPerTurn"] = int(api_ms / turns)
        if total_ms > 0:
            net["apiTimePercent"] = int(api_ms * 100 / total_ms)
        state["network"] = net

    # Merge model info (always update — model can change mid-session via /model)
    model = data.get("model", {})
    if model:
        display = model.get("display_name", "")
        mid = model.get("id", "")
        if display or mid:
            state["modelName"] = display or mid

    # Merge session name (don't overwrite user renames)
    sname = data.get("session_name")
    if sname and not state.get("sessionNameOverride"):
        state["sessionName"] = sname

    # Persist the final displayed cost for this Claude Code session so a reopen
    # can restore it as the next process's baseline.
    if cost:
        cc_session_id = data.get("session_id") or state.get("claudeCodeSessionId", "")
        if cc_session_id:
            persist_path = os.path.expanduser("~/.claude-terminal/cost-by-session.json")
            persist_dir = os.path.dirname(persist_path)
            os.makedirs(persist_dir, exist_ok=True)
            try:
                with open(persist_path) as f:
                    persist = json.load(f)
            except Exception:
                persist = {}
            persist[cc_session_id] = state["cost"]
            pfd, ptmp = tempfile.mkstemp(dir=persist_dir, suffix=".json")
            try:
                with os.fdopen(pfd, "w") as f:
                    json.dump(persist, f)
                os.replace(ptmp, persist_path)
            except Exception:
                try:
                    os.unlink(ptmp)
                except OSError:
                    pass

    # Atomic write
    fd, tmp = tempfile.mkstemp(dir=status_dir, suffix=".json")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(state, f)
        os.replace(tmp, status_file)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
    """
}
