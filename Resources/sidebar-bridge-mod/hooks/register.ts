import type { EngineInterface, Register, Timer } from 'claude-code'
import { atom, read, update } from 'claude-code'
import type {
  SidebarBridgeApiMs,
  SidebarBridgeBreakdown,
  SidebarBridgeContextRow,
  SidebarBridgeEffort,
  SidebarBridgeStarted,
  SidebarBridgeStartedAt,
} from '../types'

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

// Every helper run takes the same flock on .status.lock, so they finish one at
// a time however many are started. Runs started faster than they finish (the
// 3 s poll, PR lookups, the breakdown, a burst of tool calls) used to queue on
// that lock, and the one at the back passed TIMEOUT_MS and was killed. Each
// send now waits for the one before it, so a run's TIMEOUT_MS counts its own
// work and not the queue's.
let lastSend: Promise<void> = Promise.resolve()

// `repeats`: the next status poll sends the same figures within STATUS_POLL_MS,
// so a run that fails is dropped with no message.
type SendOptions = { repeats?: boolean }

function send($: EngineInterface, subcommand: 'hook' | 'statusline', payload: Record<string, unknown>, options: SendOptions = {}) {
  const run = lastSend.then(() => runHelper($, subcommand, payload, options))
  lastSend = run
  return run
}

async function runHelper(
  $: EngineInterface,
  subcommand: 'hook' | 'statusline',
  payload: Record<string, unknown>,
  options: SendOptions,
) {
  helper ??= await $.env.get('CLAUDE_TERMINAL_HOOK')
  if (!helper) return
  const stdin = JSON.stringify({
    session_id: await $.session.id(),
    cwd: await $.session.cwd(),
    ...payload,
  })
  // cwd "/": the helper reads the session's directory from stdin, never its
  // own. Run in the session's directory, a spawn fails once that directory is
  // gone (a removed git worktree, say), and posix_spawn reports it as ENOENT on
  // the helper's path.
  const attempt = () => $.process.run([helper!, subcommand], { stdin, cwd: '/', timeoutMs: TIMEOUT_MS })
  try {
    await attempt()
  } catch (err) {
    // A run throws when it passes TIMEOUT_MS or cannot start; a helper that
    // fails exits non-zero and does not throw. The timeouts come almost all
    // from sleep: a dark wake starts a run, the Mac sleeps again before it
    // ends, and the timer counts the sleep. The helper takes about 30 ms.
    if (options.repeats) return
    // Nothing sends this one again, so it gets one more try: by then the Mac
    // is awake. A run the timeout cut after its write does no harm twice.
    try {
      await attempt()
      return
    } catch (retryErr) {
      err = retryErr
    }
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

// The /context breakdown. A full one asks the API to count each tool and
// memory file, about one request per tool, so it runs at session start, after
// a compact and when the person presses Refresh. Between those the fixed rows
// hold, and each turn rebuilds Messages from the main context's input tokens.
const breakdown = atom({ plugin: 'sidebar-bridge', key: 'breakdown' } as const, null as SidebarBridgeBreakdown)

// The main loop's effort level. No call reads it: each request's turn.step
// carries it, and an /effort this mod runs sets it before the next request.
const effort = atom({ plugin: 'sidebar-bridge', key: 'effort' } as const, null as SidebarBridgeEffort)

const EFFORTS = ['low', 'medium', 'high', 'xhigh', 'max']

// Rows the context is made of besides the conversation: kept from the last full
// breakdown. Messages, Free space and the compact buffer are worked out again.
const MESSAGES = 'Messages'

async function measureBreakdown($: EngineInterface) {
  const usage = await $.session.usage({ breakdown: 'full' })
  const b = usage.context.breakdown
  if (!b) return
  const now = await $.clock.now()
  const messagesTokens = b.categories.find(c => c.name === MESSAGES)?.tokens ?? 0
  await update($, breakdown, () => ({
    rows: b.categories
      .filter(c => c.kind === 'used' && c.name !== MESSAGES)
      .map(c => ({ name: c.name, tokens: c.tokens, kind: c.kind })),
    messagesTokens,
    inputTokensAtMeasure: usage.context.tokens ?? null,
    windowTokens: b.rawMaxTokens,
    mcpTools: b.mcpTools.map(t => ({ name: t.name, server: t.serverName, tokens: t.tokens })),
    memoryFiles: b.memoryFiles.map(f => ({ path: f.path, tokens: f.tokens })),
    measuredAt: now,
  }))
  await sendBreakdown($)
}

// Sends the breakdown with Messages, Free space and the buffer for now.
//
// usage.context.tokens is the last API response's input: the conversation plus
// the fixed rows. Right after a compact no response has come back, so it is
// absent or still the pre-compact figure; the full count made then is the only
// true Messages. So the full count's Messages stands until the input tokens
// move on from what they were when it ran, and after that Messages is what is
// left of them once the fixed rows are taken out.
async function sendBreakdown($: EngineInterface) {
  const b = await read($, breakdown)
  if (!b) return
  const usage = await $.session.usage()
  const fixed = b.rows.reduce((sum, r) => sum + r.tokens, 0)
  const input = usage.context.tokens
  const isNewer = input !== undefined && input !== b.inputTokensAtMeasure
  const messages = isNewer ? Math.max(0, input - fixed) : b.messagesTokens
  const buffer = Math.min(3000, b.windowTokens)
  const used = fixed + messages
  const rows: SidebarBridgeContextRow[] = [
    ...b.rows,
    { name: MESSAGES, tokens: messages, kind: 'used' },
    { name: 'Compact buffer', tokens: buffer, kind: 'buffer' },
    { name: 'Free space', tokens: Math.max(0, b.windowTokens - used - buffer), kind: 'free' },
  ]
  await send($, 'statusline', {
    context_breakdown: {
      window_tokens: b.windowTokens,
      used_tokens: used,
      measured_at: b.measuredAt,
      rows,
      mcp_tools: [...b.mcpTools].sort((x, y) => y.tokens - x.tokens),
      memory_files: [...b.memoryFiles].sort((x, y) => y.tokens - x.tokens),
    },
  })
}

// The app writes `{ "action": "refresh" | "compact" }` to this file in the
// session's status directory when the person presses a sidebar button. The mod
// polls it, as the app has no way to call into the session.
const REQUEST_POLL_MS = 1000

async function requestPath($: EngineInterface): Promise<string | undefined> {
  const dir = await $.env.get('CLAUDE_TERMINAL_STATUS_DIR')
  return dir ? `${dir}/mod-request.json` : undefined
}

type Request = { action?: unknown; value?: unknown }

// Reads and consumes a pending request. The file is emptied, not removed:
// $.fs has no delete. An empty or unreadable file is no request.
async function takeRequest($: EngineInterface): Promise<Request | undefined> {
  const path = await requestPath($)
  if (!path || !(await $.fs.exists(path))) return undefined
  const text = await $.fs.read(path).catch(() => '')
  if (!text.trim()) return undefined
  await $.fs.write(path, '')
  try {
    const request = JSON.parse(text) as Request
    return typeof request?.action === 'string' ? request : undefined
  } catch {
    return undefined
  }
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

// A model or effort the person picked in the sidebar's model menu. Each runs
// the slash command, as typing it would, for this session only. The value
// comes from a file, so only a plain model name or a known level is passed on.
const MODEL_NAME = /^[A-Za-z0-9][A-Za-z0-9._\-]*(\[[A-Za-z0-9]+\])?$/

async function switchTo($: EngineInterface, action: 'model' | 'effort', value: unknown) {
  if (typeof value !== 'string') return
  if (action === 'model' ? !MODEL_NAME.test(value) : !EFFORTS.includes(value)) return
  try {
    await $.command.run({ command: action, args: value })
    if (action === 'effort') await update($, effort, () => value)
  } catch (err) {
    $.ui.log(`sidebar-bridge: /${action} ${value} failed: ${String(err)}`)
  }
  await statusLine($)
}

// The statusLine payload, built from $.session.usage(). Cost is the session's
// cumulative total, as total_cost_usd was, so the binary's /clear baseline still
// subtracts; the two durations are cumulative the same way. The pull request
// comes from sendPr, the context breakdown from sendBreakdown. No native source gives Claude Code's own session name.
async function statusLine($: EngineInterface) {
  const usage = await $.session.usage()
  const begun = await read($, startedAt)
  const durationMs = begun > 0 ? Math.max(0, (await $.clock.now()) - begun) : 0
  const settings = ((await $.settings.read().catch(() => ({}))) ?? {}) as { model?: unknown; effortLevel?: unknown }
  // Before the first request, the saved effort is the one it will use.
  const level = (await read($, effort)) ?? (typeof settings.effortLevel === 'string' ? settings.effortLevel : null)
  await send($, 'statusline', {
    model: { id: await $.session.model() },
    ...(level ? { effort: level } : {}),
    ...(typeof settings.model === 'string' ? { default_model: settings.model } : {}),
    cost: {
      total_cost_usd: usage.cost?.usd ?? 0,
      total_duration_ms: durationMs,
      total_api_duration_ms: await read($, apiMs),
    },
  }, { repeats: true })
}

// This module load's timers. A reload starts a fresh module, and the engine
// drops the old one's timers, so module scope holds them.
const timers: { status?: Timer; pr?: Timer; request?: Timer } = {}
let isCompacting = false

// Runs the request the app wrote. Refresh measures the breakdown again;
// Compact compacts the main conversation, then session.compact measures;
// model and effort switch the session's.
async function serveRequest($: EngineInterface) {
  const request = await takeRequest($)
  const action = request?.action
  if (action === 'model' || action === 'effort') {
    await switchTo($, action, request?.value)
  } else if (action === 'refresh') {
    await measureBreakdown($)
  } else if (action === 'compact' && !isCompacting) {
    isCompacting = true
    await send($, 'statusline', { compacting: true })
    try {
      await $.session.compact()
    } catch (err) {
      $.ui.log(`sidebar-bridge: compact failed: ${String(err)}`)
    } finally {
      isCompacting = false
      await send($, 'statusline', { compacting: false })
    }
  }
}

// One status poll at a time: a tick that finds the last one still queued
// behind slow helper runs skips, as the next tick carries the same figures.
let isPolling = false

async function pollStatus($: EngineInterface) {
  if (isPolling) return
  isPolling = true
  try {
    await statusLine($)
  } finally {
    isPolling = false
  }
}

function startPolls($: EngineInterface) {
  stopPolls()
  timers.status = $.clock.every(STATUS_POLL_MS, () => void pollStatus($))
  timers.pr = $.clock.every(PR_POLL_MS, () => void sendPr($))
  timers.request = $.clock.every(REQUEST_POLL_MS, () => void serveRequest($))
}

function stopPolls() {
  timers.status?.cancel()
  timers.pr?.cancel()
  timers.request?.cancel()
  timers.status = timers.pr = timers.request = undefined
}

export const register: Register = on => {
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
    startPolls($)
    await statusLine($)
    void sendPr($)
    // A reload keeps the last breakdown in $.state; a fresh session measures.
    if (await read($, breakdown)) void sendBreakdown($)
    else void measureBreakdown($)
    return result
  })

  on('session.end', async ($, e, next) => {
    stopPolls()
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
      await hook($, { hook_event_name: 'SessionStart', source: 'clear', model: await $.session.model() })
      startPolls($)
      void measureBreakdown($)
    }
    return result
  })

  // A compact rewrites the conversation: measure the context it left. Only the
  // main conversation's, and not a precompute that may never be applied.
  on('session.compact', async ($, e, next) => {
    const result = await next(e)
    if (!e.agentId && e.trigger !== 'precompute' && !('skip' in result && result.skip)) {
      void measureBreakdown($)
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
    // The main context grew by this turn: Messages follows its input tokens.
    if (!e.agentId) await sendBreakdown($)
    return result
  })

  // The level each main-loop request goes out with: an /effort the person
  // typed, or the model's own default after a /model, shows from here.
  on('turn.step', async function* ($, e, next) {
    if (!e.agentId && typeof e.effort === 'string' && e.effort !== (await read($, effort))) {
      const level = e.effort
      await update($, effort, () => level)
      void statusLine($)
    }
    return yield* next(e)
  })
    // Sidebar bookkeeping only: if it fails, pass the request on as it was.
    .catch(async function* ($, e, next) {
      return yield* next(e)
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
