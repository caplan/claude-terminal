import type { EngineInterface, Register } from 'claude-code'

// Loaded only in sessions claude-terminal launches, via CLAUDE_CODE_PLUGIN_DIRS.
// It carries the hot path that settings.json hooks carry on older Claude Code
// builds: tool start, tool end and turn end. Each event is turned into the
// stdin JSON the claude-terminal-hook binary already reads, so status.json is
// written by one code path in both modes.
//
// The low-frequency events (SessionStart, UserPromptSubmit, Subagent*, Task*,
// Notification, PermissionDenied) stay as settings.json hooks: their classic
// input has fields no native event carries (permission_mode, source,
// agent_transcript_path, notification_type). This module does not hook
// classic.* events: the built-in cc-plugin-sec-default skips user-tier hooks
// on them.

// Same budget as the settings.json entries (`"timeout": 5`).
const TIMEOUT_MS = 5000

let helper: string | undefined

async function forward($: EngineInterface, payload: Record<string, unknown>) {
  helper ??= await $.env.get('CLAUDE_TERMINAL_HOOK')
  if (!helper) return
  try {
    // Awaited so events reach status.json in the order they happened, as the
    // settings hooks do.
    await $.process.run([helper, 'hook'], {
      stdin: JSON.stringify({
        session_id: await $.session.id(),
        cwd: await $.session.cwd(),
        ...payload,
      }),
      timeoutMs: TIMEOUT_MS,
    })
  } catch (err) {
    $.ui.log(`sidebar-bridge: hook forward failed: ${String(err)}`)
  }
}

export const register: Register = on => {
  on('tool.call', async ($, e, next) => {
    const { tool, tool_use_id, agentId, ...toolInput } = e
    const ids = {
      tool_name: tool,
      tool_use_id,
      ...(agentId ? { agent_id: agentId } : {}),
    }
    await forward($, { hook_event_name: 'PreToolUse', ...ids, tool_input: toolInput })
    const result = await next(e)
    await forward($, {
      hook_event_name: result.isError ? 'PostToolUseFailure' : 'PostToolUse',
      ...ids,
      tool_input: toolInput,
    })
    return result
  })

  // The main loop's turn end is the classic Stop. A subagent's turn carries
  // agentId and is left to the settings.json SubagentStop hook.
  on('turn.complete', async ($, e, next) => {
    const result = await next(e)
    if (!e.agentId) await forward($, { hook_event_name: 'Stop' })
    return result
  })
}
