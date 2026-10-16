import type { EngineInterface, Register, Timer } from 'claude-code'
import { atom, read, update } from 'claude-code'
import type { SidebarBridgeApiMs, SidebarBridgeStarted } from '../types'

// Loaded in each session claude-terminal launches, via CLAUDE_CODE_PLUGIN_DIRS.
// It is the app's whole Claude Code integration: nothing is written to
// ~/.claude/settings.json. Each native event becomes the stdin JSON the
// claude-terminal-hook binary reads, under the classic hook name the binary
// already handles, so status.json and the /clear cost baseline keep one writer.
//
// No classic.* events: the built-in cc-plugin-sec-default skips user-tier hooks
// on them wherever managed settings exist.

// The settings hooks ran with `"timeout": 5`.
const TIMEOUT_MS = 5000

// The statusLine ran every 3 s. session.measure only fires when context, cost
// or a rate limit moves, so model and repo changes come from this poll.
const STATUS_POLL_MS = 3000

// Held by the host for the session, so a hot reload keeps it.
const started = atom({ plugin: 'sidebar-bridge', key: 'started' } as const, false as SidebarBridgeStarted)

let helper: string | undefined

async function send($: EngineInterface, subcommand: 'hook' | 'statusline', payload: Record<string, unknown>) {
  helper ??= await $.env.get('CLAUDE_TERMINAL_HOOK')
  if (!helper) return
  try {
    // Awaited so events reach status.json in the order they happened.
    await $.process.run([helper, subcommand], {
      stdin: JSON.stringify({
        session_id: await $.session.id(),
        cwd: await $.session.cwd(),
        ...payload,
      }),
      timeoutMs: TIMEOUT_MS,
    })
  } catch (err) {
    $.ui.log(`sidebar-bridge: ${subcommand} failed: ${String(err)}`)
  }
}

const hook = ($: EngineInterface, payload: Record<string, unknown>) => send($, 'hook', payload)

// How long an "ask" waits before it counts as a dialog the person must answer.
// tool.check says "ask" before the mode settles it, and auto mode's classifier
// then approves or refuses in about 1.5 s with no dialog. A call still pending
// past this is in front of the person. No native event reports the dialog
// itself, and no settings file reliably names the mode.
const ASK_SETTLE_MS = 4000

// Summed model time of the main loop's turns, the statusLine's
// total_api_duration_ms. Held by the host so a hot reload keeps it; turn.complete
// adds to it.
const apiMs = atom({ plugin: 'sidebar-bridge', key: 'apiMs' } as const, 0 as SidebarBridgeApiMs)

// The statusLine payload, built from $.session.usage(). Cost is the session's
// cumulative total, as total_cost_usd was, so the binary's /clear baseline still
// subtracts; the two durations are cumulative the same way. No native source
// gives the line counts, session name or pull request, so they are left out.
async function statusLine($: EngineInterface) {
  const usage = await $.session.usage()
  const { context } = usage
  const durationMs = Math.max(0, (await $.clock.now()) - usage.startedAt)
  await send($, 'statusline', {
    model: { id: await $.session.model() },
    context_window: {
      context_window_size: context.window,
      ...(context.percent !== undefined
        ? { used_percentage: context.percent, remaining_percentage: 100 - context.percent }
        : {}),
      ...(context.tokens !== undefined ? { total_input_tokens: context.tokens } : {}),
    },
    cost: {
      total_cost_usd: usage.cost?.usd ?? 0,
      total_duration_ms: durationMs,
      total_api_duration_ms: await read($, apiMs),
    },
  })
}

export const register: Register = on => {
  let poll: Timer | undefined
  // An "ask" verdict's wait, by tool_use_id, until the call is answered.
  const pendingAsks = new Map<string, Timer>()

  on('session.start', async ($, e, next) => {
    // Fires on each module load. Only the first per process is a session start;
    // a hot reload must not reset the sidebar.
    const result = await next(e)
    if (!(await read($, started))) {
      await update($, started, () => true)
      await hook($, { hook_event_name: 'SessionStart', source: 'startup', model: await $.session.model() })
    }
    poll?.cancel()
    poll = $.clock.every(STATUS_POLL_MS, () => void statusLine($))
    await statusLine($)
    return result
  })

  on('session.end', async ($, e, next) => {
    poll?.cancel()
    poll = undefined
    const result = await next(e)
    // /clear ends the session with no session.start after it. The binary's
    // SessionStart with source "clear" resets the sidebar and sets the cost
    // baseline. The process lives on, so the poll starts again.
    if (e.reason === 'clear') {
      // usage.startedAt starts over at /clear; the turn time does too. The
      // binary snapshots the first poll after this as its baseline, which is
      // right whether a figure restarts here or keeps counting.
      await update($, apiMs, () => 0)
      await hook($, { hook_event_name: 'SessionStart', source: 'clear', model: await $.session.model() })
      poll = $.clock.every(STATUS_POLL_MS, () => void statusLine($))
    }
    return result
  })

  on('session.measure', async ($, e, next) => {
    const result = await next(e)
    await statusLine($)
    return result
  })

  on('prompt.submit', async ($, e, next) => {
    const result = await next(e)
    // Only the person's own prompts start a turn the sidebar counts. A
    // subagent's hand-back and other injected prompts arrive here too.
    if (e.origin.kind === 'composer' || e.origin.kind === 'bridge') {
      await hook($, { hook_event_name: 'UserPromptSubmit', prompt: e.text })
    }
    return result
  })
    // Sidebar bookkeeping only: if it fails, pass the engine's own answer on.
    .catch(($, e, next) => next(e))

  on('tool.call', async ($, e, next) => {
    const { tool, tool_use_id, agentId, ...toolInput } = e
    const ids = {
      tool_name: tool,
      tool_use_id,
      ...(agentId ? { agent_id: agentId } : {}),
    }
    await hook($, { hook_event_name: 'PreToolUse', ...ids, tool_input: toolInput })
    const result = await next(e)
    // next(e) holds through the permission check: the ask, if any, is settled.
    pendingAsks.get(tool_use_id)?.cancel()
    pendingAsks.delete(tool_use_id)
    await hook($, {
      hook_event_name: result.isError ? 'PostToolUseFailure' : 'PostToolUse',
      ...ids,
      tool_input: toolInput,
    })
    // TaskCreated: the task's id exists only in the tool's result.
    if (tool === 'TaskCreate' && !result.isError && result.result) {
      const { task } = result.result as { task?: { id: string; subject: string } }
      if (task) await hook($, { hook_event_name: 'TaskCreated', task_id: task.id, task_subject: task.subject })
    }
    return result
  })
    // Sidebar bookkeeping only: if it fails, pass the engine's own answer on.
    .catch(($, e, next) => next(e))

  // A spawn's answer carries the agent's id. Its turn.complete is SubagentStop.
  on('agent.spawn', async ($, e, next) => {
    const result = await next(e)
    if (result.agentId) {
      await hook($, {
        hook_event_name: 'SubagentStart',
        agent_id: result.agentId,
        agent_type: e.subagentType,
        description: e.description,
      })
    }
    return result
  })
    // Sidebar bookkeeping only: if it fails, pass the engine's own answer on.
    .catch(($, e, next) => next(e))

  on('turn.complete', async ($, e, next) => {
    const result = await next(e)
    if (!e.agentId) await update($, apiMs, ms => ms + e.durationMs)
    await hook($, e.agentId ? { hook_event_name: 'SubagentStop', agent_id: e.agentId } : { hook_event_name: 'Stop' })
    return result
  })

  // A permission ask: the Notification the binary reads as "needs input". It
  // waits ASK_SETTLE_MS for the mode to settle the ask; the call's own
  // tool.call hook, below, cancels the wait once the call is answered.
  on('tool.check', async ($, e, next) => {
    const result = await next(e)
    const id = e.tool_use_id
    if (result.decision === 'ask' && !result.decider && id) {
      pendingAsks.get(id)?.cancel()
      pendingAsks.set(
        id,
        $.clock.after(ASK_SETTLE_MS, () => {
          pendingAsks.delete(id)
          void hook($, {
            hook_event_name: 'Notification',
            notification_type: 'permission_prompt',
            ...(e.agentId ? { agent_id: e.agentId } : {}),
          })
        }),
      )
    }
    return result
  })
    // Sidebar bookkeeping only: if it fails, pass the engine's own answer on.
    .catch(($, e, next) => next(e))
}
