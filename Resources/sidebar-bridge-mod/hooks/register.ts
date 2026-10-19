import type { EngineInterface, Register, Timer } from 'claude-code'
import { atom, read, update } from 'claude-code'
import type { SidebarBridgeApiMs, SidebarBridgeStarted, SidebarBridgeStartedAt, SidebarBridgeTotals } from '../types'

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

// When this process's session began. usage.startedAt is a resumed session's
// first launch, which made `--continue` report days of duration; the
// statusLine's total_duration_ms counted from this process's start.
const startedAt = atom({ plugin: 'sidebar-bridge', key: 'startedAt' } as const, 0 as SidebarBridgeStartedAt)

// Figures the statusLine reported and $.session.usage() does not: output
// tokens summed from turn.complete's usage; the last main-loop response's cache
// tokens, as current_usage held them; and lines added and removed summed from
// each Edit and Write call's structuredPatch.
const ZERO_TOTALS: SidebarBridgeTotals = {
  outputTokens: 0,
  cacheReadTokens: 0,
  cacheCreationTokens: 0,
  linesAdded: 0,
  linesRemoved: 0,
}
const totals = atom({ plugin: 'sidebar-bridge', key: 'totals' } as const, ZERO_TOTALS)

// The file tools whose result carries a structuredPatch.
const EDIT_TOOLS = new Set(['Edit', 'Write', 'MultiEdit', 'NotebookEdit'])

// Counts a result's `+` and `-` patch lines. The optional gitDiff's additions
// and deletions would say the same, but the engine leaves gitDiff out of most
// results; structuredPatch is always there for an edit that changed a file.
function lineCounts(result: unknown): { added: number; removed: number } | undefined {
  const hunks = (result as { structuredPatch?: unknown } | undefined)?.structuredPatch
  if (!Array.isArray(hunks)) return undefined
  let added = 0
  let removed = 0
  for (const hunk of hunks) {
    for (const line of (hunk as { lines?: unknown }).lines as unknown[] ?? []) {
      if (typeof line !== 'string') continue
      if (line.startsWith('+')) added++
      else if (line.startsWith('-')) removed++
    }
  }
  return { added, removed }
}

// The open pull request for the session's branch. No native source names it,
// so `gh pr view` asks GitHub. It is a network call, so it runs on its own,
// slower poll, and again after a Bash call that created or changed a PR.
const PR_POLL_MS = 60_000
const PR_TIMEOUT_MS = 10_000

// The statusLine `pr` block the binary reads: an object, or null for none.
type PrBlock = { number: number; url: string; review_state: string } | null

// What `gh pr view --json` prints for the fields asked.
type GhPr = { number: number; url: string; state: string; isDraft: boolean; reviewDecision: string }

// The sidebar's review labels: draft, approved, changes_requested, pending.
function reviewState(pr: GhPr): string {
  if (pr.isDraft) return 'draft'
  switch (pr.reviewDecision) {
    case 'APPROVED': return 'approved'
    case 'CHANGES_REQUESTED': return 'changes_requested'
    case 'REVIEW_REQUIRED': return 'pending'
    default: return ''
  }
}

// undefined when gh could not answer (not installed, signed out, offline):
// the binary then keeps the PR it last saw. `gh pr view` exits 1 with "no pull
// requests found" when the branch has none, which is a real answer.
async function lookUpPr($: EngineInterface): Promise<PrBlock | undefined> {
  try {
    const { exitCode, stdout, stderr } = await $.process.run(
      ['gh', 'pr', 'view', '--json', 'number,url,state,isDraft,reviewDecision'],
      { timeoutMs: PR_TIMEOUT_MS },
    )
    if (exitCode !== 0) return /no pull requests found/i.test(stderr) ? null : undefined
    const pr = JSON.parse(stdout) as GhPr
    if (pr.state !== 'OPEN') return null
    return { number: pr.number, url: pr.url, review_state: reviewState(pr) }
  } catch {
    return undefined
  }
}

async function sendPr($: EngineInterface) {
  const pr = await lookUpPr($)
  if (pr !== undefined) await send($, 'statusline', { pr })
}

// The statusLine payload, built from $.session.usage(). Cost is the session's
// cumulative total, as total_cost_usd was, so the binary's /clear baseline still
// subtracts; the two durations are cumulative the same way. The token and line
// totals come from `totals`, the pull request from sendPr. No native source
// gives Claude Code's own session name.
async function statusLine($: EngineInterface) {
  const usage = await $.session.usage()
  const { context } = usage
  const begun = await read($, startedAt)
  const durationMs = begun > 0 ? Math.max(0, (await $.clock.now()) - begun) : 0
  const t = await read($, totals)
  await send($, 'statusline', {
    model: { id: await $.session.model() },
    context_window: {
      context_window_size: context.window,
      ...(context.percent !== undefined
        ? { used_percentage: context.percent, remaining_percentage: 100 - context.percent }
        : {}),
      ...(context.tokens !== undefined ? { total_input_tokens: context.tokens } : {}),
      total_output_tokens: t.outputTokens,
      current_usage: {
        cache_read_input_tokens: t.cacheReadTokens,
        cache_creation_input_tokens: t.cacheCreationTokens,
      },
    },
    cost: {
      total_cost_usd: usage.cost?.usd ?? 0,
      total_duration_ms: durationMs,
      total_api_duration_ms: await read($, apiMs),
      total_lines_added: t.linesAdded,
      total_lines_removed: t.linesRemoved,
    },
  })
}

export const register: Register = on => {
  let poll: Timer | undefined
  let prPoll: Timer | undefined
  // An "ask" verdict's wait, by tool_use_id, until the call is answered.
  const pendingAsks = new Map<string, Timer>()

  on('session.start', async ($, e, next) => {
    // Fires on each module load. Only the first per process is a session start;
    // a hot reload must not reset the sidebar.
    const result = await next(e)
    if (!(await read($, started))) {
      await update($, started, () => true)
      const now = await $.clock.now()
      await update($, startedAt, () => now)
      await hook($, { hook_event_name: 'SessionStart', source: 'startup', model: await $.session.model() })
    }
    poll?.cancel()
    poll = $.clock.every(STATUS_POLL_MS, () => void statusLine($))
    prPoll?.cancel()
    prPoll = $.clock.every(PR_POLL_MS, () => void sendPr($))
    await statusLine($)
    void sendPr($)
    return result
  })

  on('session.end', async ($, e, next) => {
    poll?.cancel()
    poll = undefined
    prPoll?.cancel()
    prPoll = undefined
    const result = await next(e)
    // /clear ends the session with no session.start after it. The binary's
    // SessionStart with source "clear" resets the sidebar and sets the cost
    // baseline. The process lives on, so the poll starts again.
    if (e.reason === 'clear') {
      // usage.startedAt starts over at /clear; the turn time does too. The
      // binary snapshots the first poll after this as its baseline, which is
      // right whether a figure restarts here or keeps counting.
      await update($, apiMs, () => 0)
      const now = await $.clock.now()
      await update($, startedAt, () => now)
      await update($, totals, () => ZERO_TOTALS)
      await hook($, { hook_event_name: 'SessionStart', source: 'clear', model: await $.session.model() })
      poll = $.clock.every(STATUS_POLL_MS, () => void statusLine($))
      prPoll = $.clock.every(PR_POLL_MS, () => void sendPr($))
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
    // A Bash call that touched a PR (gh pr create, merge, ready, ...) or moved
    // the branch reports it in gitOperation: look the PR up now, not in 60 s.
    if (tool === 'Bash' && !result.isError && result.result) {
      const op = (result.result as { gitOperation?: { pr?: unknown; push?: unknown; branch?: unknown } }).gitOperation
      if (op?.pr || op?.push || op?.branch) void sendPr($)
    }
    if (EDIT_TOOLS.has(tool) && !result.isError) {
      const lines = lineCounts(result.result)
      if (lines) {
        await update($, totals, t => ({
          ...t,
          linesAdded: t.linesAdded + lines.added,
          linesRemoved: t.linesRemoved + lines.removed,
        }))
      }
    }
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
    // Output tokens count from every loop, a subagent's too. The cache figures
    // describe the main context, so only the main loop's replace them.
    const u = e.usage
    if (u) {
      await update($, totals, t => ({
        ...t,
        outputTokens: t.outputTokens + u.output_tokens,
        ...(e.agentId
          ? {}
          : { cacheReadTokens: u.cache_read_input_tokens, cacheCreationTokens: u.cache_creation_input_tokens }),
      }))
    }
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
