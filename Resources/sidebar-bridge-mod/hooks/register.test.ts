import type { On } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'

const HELPER = '/app/Contents/Resources/claude-terminal-hook'

type Sent = { subcommand: string; payload: Record<string, unknown> }

type Gh = { exitCode: number; stdout?: string; stderr?: string }

const run = (r: Gh) => ({
  value: { exitCode: r.exitCode, stdout: r.stdout ?? '', stderr: r.stderr ?? '', isStdoutTruncated: false, isStderrTruncated: false },
})

// Stands for the claude-terminal-hook binary: records what the mod sends.
// `gh` answers as `gh pr view` would; by default the branch has no PR.
// What `$.session.usage({ breakdown: 'full' })` answers, as the engine's
// /context counts it: the same rows a live session returned.
const FULL_BREAKDOWN = {
  categories: [
    { name: 'System prompt', tokens: 2000, color: 'promptBorder', isDeferred: false, kind: 'used' },
    { name: 'System tools', tokens: 6000, color: 'inactive', isDeferred: false, kind: 'used' },
    { name: 'MCP tools', tokens: 46000, color: 'cyan', isDeferred: false, kind: 'used' },
    { name: 'Messages', tokens: 0, color: 'purple', isDeferred: false, kind: 'used' },
    { name: 'Compact buffer', tokens: 3000, color: 'inactive', isDeferred: false, kind: 'buffer' },
    { name: 'Free space', tokens: 143000, color: 'promptBorder', isDeferred: false, kind: 'free' },
  ],
  totalTokens: 54000, maxTokens: 200000, rawMaxTokens: 200000, autocompactSource: 'model', percentage: 27,
  gridRows: [], model: 'claude-opus-5-5',
  memoryFiles: [{ path: '/work/CLAUDE.md', type: 'Project', tokens: 900 }, { path: '/u/.claude/CLAUDE.md', type: 'User', tokens: 1500 }],
  mcpTools: [{ name: 'search', serverName: 'glean', tokens: 300, isLoaded: true }, { name: 'query', serverName: 'datadog', tokens: 2200, isLoaded: true }],
  agents: [], isAutoCompactEnabled: true, apiUsage: null,
}

type Options = {
  gh?: Gh
  usageStartedAt?: number
  /** The main context's input tokens, `usage.context.tokens`; null leaves them out. */
  contextTokens?: number | null
  /** Read on each call, so a test can move the context mid-way. */
  live?: { contextTokens: number | null; messagesTokens: number }
  /** What the app wrote to mod-request.json, or undefined for no file. */
  request?: { text: string }
}

function helper(
  on: On,
  gh: Gh = { exitCode: 1, stderr: 'no pull requests found for branch "main"' },
  usageStartedAt = 0,
  options: Omit<Options, 'gh' | 'usageStartedAt'> = {},
): Sent[] {
  const sent: Sent[] = []
  mock.env(on, { CLAUDE_TERMINAL_HOOK: HELPER, CLAUDE_TERMINAL_STATUS_DIR: '/status' })
  const request = options.request
  on('fs.exists', ($, e) => ({ value: e.path === '/status/mod-request.json' && request !== undefined }))
  on('fs.read', () => ({ value: request?.text ?? '' }))
  on('fs.write', ($, e) => {
    if (request && e.path === '/status/mod-request.json') request.text = e.text
    return { value: undefined }
  })
  on('process.run', ($, e) => {
    if (e.argv[0] === 'gh') return run(gh)
    if (e.argv[0] === HELPER) {
      sent.push({ subcommand: e.argv[1] ?? '', payload: JSON.parse(e.init?.stdin ?? '{}') })
    }
    return run({ exitCode: 0 })
  })
  on('session.id', () => ({ value: 'cc-session' }))
  on('session.cwd', () => ({ value: '/work' }))
  on('session.model', () => ({ value: 'claude-opus-5-5' }))
  on('session.usage', ($, e) => {
    const tokens = options.live ? options.live.contextTokens : options.contextTokens === undefined ? 1000 : options.contextTokens
    const messages = options.live?.messagesTokens ?? 0
    const full = {
      ...FULL_BREAKDOWN,
      categories: FULL_BREAKDOWN.categories.map(c => (c.name === 'Messages' ? { ...c, tokens: messages } : c)),
    }
    return {
      value: {
        startedAt: usageStartedAt,
        context: {
          ...(tokens === null ? {} : { tokens }),
          window: 200000,
          percent: 1,
          ...(e?.breakdown ? { breakdown: full } : {}),
        },
        rateLimits: [],
        cost: { usd: 0.25 },
      },
    }
  })
  return sent
}

const events = (sent: Sent[]) =>
  sent.filter(s => s.subcommand === 'hook').map(s => s.payload.hook_event_name)

test('a tool call sends PreToolUse then PostToolUse with its input', async ($, on) => {
  const sent = helper(on)
  on('tool.call', () => ({ result: { stdout: 'hi' }, isError: false }))
  await $.tool.call({ tool: 'Bash', tool_use_id: 't1', command: 'echo hi' })
  const hooks = sent.filter(s => s.subcommand === 'hook')
  expect(hooks.map(h => h.payload.hook_event_name)).toEqual(['PreToolUse', 'PostToolUse'])
  expect(hooks[0]?.payload.tool_input).toEqual({ command: 'echo hi' })
  expect(hooks[0]?.payload.session_id).toEqual('cc-session')
})

test('a failed call sends PostToolUseFailure', async ($, on) => {
  const sent = helper(on)
  on('tool.call', () => ({ result: undefined, isError: true, text: 'boom' }))
  await $.tool.call({ tool: 'Bash', tool_use_id: 't2', command: 'false' })
  expect(events(sent)).toEqual(['PreToolUse', 'PostToolUseFailure'])
})

test("TaskCreate's result becomes TaskCreated", async ($, on) => {
  const sent = helper(on)
  on('tool.call', () => ({ result: { task: { id: '7', subject: 'write tests' } }, isError: false }))
  await $.tool.call({ tool: 'TaskCreate', tool_use_id: 't3', subject: 'write tests', description: 'd' })
  const created = sent.find(s => s.payload.hook_event_name === 'TaskCreated')
  expect(created?.payload).toMatchObject({ task_id: '7', task_subject: 'write tests' })
})

test('turn.complete is Stop on the main loop and SubagentStop in an agent', async ($, on) => {
  const sent = helper(on)
  on('turn.complete', () => ({ text: '' }))
  const base = { answer: 'ok', durationMs: 1200, isAborted: false, reason: 'answer' as const }
  await $.turn.complete({ ...base, turnId: 'a' })
  await $.turn.complete({ ...base, turnId: 'b', agentId: 'agent-1' })
  const hooks = sent.filter(s => s.subcommand === 'hook').map(s => s.payload)
  expect(hooks).toEqual([
    expect.objectContaining({ hook_event_name: 'Stop' }),
    expect.objectContaining({ hook_event_name: 'SubagentStop', agent_id: 'agent-1' }),
  ])
})

test('only prompts the person typed count as UserPromptSubmit', async ($, on) => {
  const sent = helper(on)
  on('prompt.submit', ($, e) => ({ text: e.text }))
  await $.prompt.submit({ text: 'typed', wait: false, origin: { kind: 'composer' } })
  await $.prompt.submit({ text: 'a hand-back', wait: false, origin: { kind: 'sdk' } })
  const prompts = sent.filter(s => s.payload.hook_event_name === 'UserPromptSubmit')
  expect(prompts.map(p => p.payload.prompt)).toEqual(['typed'])
})

test('an ask still open after the wait sends a permission Notification', async ($, on) => {
  const sent = helper(on)
  const clock = mock.clock(on)
  on('tool.check', () => ({ decision: 'ask' as const }))
  await $.tool.check({ tool: 'Bash', input: { command: 'rm x' }, tool_use_id: 't4' })
  await clock.advance(3000)
  expect(events(sent)).toEqual([])
  await clock.advance(2000)
  expect(sent.find(s => s.payload.hook_event_name === 'Notification')?.payload).toMatchObject({
    notification_type: 'permission_prompt',
  })
})

test('an ask the mode settles in time sends no Notification', async ($, on) => {
  const sent = helper(on)
  const clock = mock.clock(on)
  on('tool.check', () => ({ decision: 'ask' as const }))
  on('tool.call', () => ({ result: { stdout: '' }, isError: false }))
  await $.tool.check({ tool: 'Bash', input: { command: 'rm x' }, tool_use_id: 't5' })
  await clock.advance(1500)
  await $.tool.call({ tool: 'Bash', tool_use_id: 't5', command: 'rm x' })
  await clock.advance(10000)
  expect(events(sent)).toEqual(['PreToolUse', 'PostToolUse'])
})

test('the status line carries model and cumulative cost, and no context window', async ($, on) => {
  const sent = helper(on)
  mock.clock(on, { now: 5000 })
  on('session.measure', ($, e) => ({ changed: e.changed }))
  await $.session.measure({ context: { tokens: 1000, window: 200000, percent: 1 }, rateLimits: [], changed: ['cost'] })
  const line = sent.find(s => s.subcommand === 'statusline')?.payload
  expect(line?.model).toEqual({ id: 'claude-opus-5-5' })
  // The context card reads the breakdown alone; the old summary is gone.
  expect(line && 'context_window' in line).toEqual(false)
  // No session.start ran here, so no start time is known yet: duration is 0.
  expect(line?.cost).toEqual({ total_cost_usd: 0.25, total_duration_ms: 0, total_api_duration_ms: 0 })
})

const prSent = (sent: Sent[]) =>
  sent.filter(s => s.subcommand === 'statusline' && 'pr' in s.payload).map(s => s.payload.pr)

const ghPr = (fields: Record<string, unknown>) => ({
  exitCode: 0,
  stdout: JSON.stringify({ number: 2566, url: 'https://github.com/o/r/pull/2566', state: 'OPEN', isDraft: false, reviewDecision: '', ...fields }),
})

test('a gh pr create in Bash sends the open PR with its review state', async ($, on) => {
  const sent = helper(on, ghPr({ reviewDecision: 'CHANGES_REQUESTED' }))
  const clock = mock.clock(on)
  on('tool.call', () => ({
    result: { stdout: '', gitOperation: { pr: { number: 2566, action: 'created' } } },
    isError: false,
  }))
  await $.tool.call({ tool: 'Bash', tool_use_id: 'b1', command: 'gh pr create --fill' })
  await clock.settle()
  expect(prSent(sent)).toEqual([
    { number: 2566, url: 'https://github.com/o/r/pull/2566', review_state: 'changes_requested' },
  ])
})

test('a draft PR is sent as draft', async ($, on) => {
  const sent = helper(on, ghPr({ isDraft: true, reviewDecision: 'APPROVED' }))
  const clock = mock.clock(on)
  on('tool.call', () => ({ result: { stdout: '', gitOperation: { push: { branch: 'f' } } }, isError: false }))
  await $.tool.call({ tool: 'Bash', tool_use_id: 'b2', command: 'git push' })
  await clock.settle()
  expect(prSent(sent)).toEqual([{ number: 2566, url: 'https://github.com/o/r/pull/2566', review_state: 'draft' }])
})

test('a merged PR, or no PR, clears the card with pr: null', async ($, on) => {
  const sent = helper(on, ghPr({ state: 'MERGED' }))
  const clock = mock.clock(on)
  on('tool.call', () => ({ result: { stdout: '', gitOperation: { pr: { number: 2566, action: 'merged' } } }, isError: false }))
  await $.tool.call({ tool: 'Bash', tool_use_id: 'b3', command: 'gh pr merge' })
  await clock.settle()
  expect(prSent(sent)).toEqual([null])
})

test('when gh cannot answer, nothing is sent and the last PR stays', async ($, on) => {
  const sent = helper(on, { exitCode: 4, stderr: 'To get started with GitHub CLI, please run: gh auth login' })
  const clock = mock.clock(on)
  on('tool.call', () => ({ result: { stdout: '', gitOperation: { pr: { number: 1, action: 'edited' } } }, isError: false }))
  await $.tool.call({ tool: 'Bash', tool_use_id: 'b4', command: 'gh pr edit' })
  await clock.settle()
  expect(prSent(sent)).toEqual([])
})

test('a Bash call with no git operation does not ask gh', async ($, on) => {
  const sent = helper(on, ghPr({}))
  const clock = mock.clock(on)
  on('tool.call', () => ({ result: { stdout: 'hi' }, isError: false }))
  await $.tool.call({ tool: 'Bash', tool_use_id: 'b5', command: 'echo hi' })
  await clock.settle()
  expect(prSent(sent)).toEqual([])
})

const lastLine = (sent: Sent[]) =>
  sent.filter(s => s.subcommand === 'statusline' && 'cost' in s.payload).at(-1)?.payload as
    | { cost: Record<string, unknown> }
    | undefined

// session.measure answered beneath the plugins; register it before the test
// first calls $, and call measure() to raise one.
function measured(on: On) {
  on('session.measure', ($, e) => ({ changed: e.changed }))
  return ($: { session: { measure: (e: { context: { tokens: number; window: number; percent: number }; rateLimits: never[]; changed: 'cost'[] }) => Promise<unknown> } }) =>
    $.session.measure({ context: { tokens: 1000, window: 200000, percent: 1 }, rateLimits: [], changed: ['cost'] })
}

test("duration counts from this process's start, not a resumed session's first launch", async ($, on) => {
  // usage.startedAt is days back, as for `claude --continue`.
  const sent = helper(on, undefined, -10 * 86_400_000)
  const clock = mock.clock(on, { now: 1_000_000 })
  const measure = measured(on)
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  await $.session.start({ cwd: '/work', surface: null, isInteractive: false })
  await clock.advance(90_000)
  await measure($)
  expect(lastLine(sent)?.cost.total_duration_ms).toEqual(90_000)
})

type SentBreakdown = {
  window_tokens: number
  used_tokens: number
  rows: { name: string; tokens: number; kind: string }[]
  mcp_tools: { name: string; tokens: number }[]
  memory_files: { path: string; tokens: number }[]
}

const breakdowns = (sent: Sent[]) =>
  sent
    .filter(s => s.subcommand === 'statusline' && 'context_breakdown' in s.payload)
    .map(s => s.payload.context_breakdown as SentBreakdown)

const rowTokens = (b: SentBreakdown | undefined, name: string) => b?.rows.find(r => r.name === name)?.tokens

test('a session start measures the breakdown and sends its rows, largest tools first', async ($, on) => {
  const sent = helper(on, undefined, 0, { contextTokens: 54000 })
  const clock = mock.clock(on)
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  await $.session.start({ cwd: '/work', surface: null, isInteractive: true })
  await clock.settle()
  const b = breakdowns(sent).at(-1)
  expect(b?.rows.map(r => r.name)).toEqual([
    'System prompt', 'System tools', 'MCP tools', 'Messages', 'Compact buffer', 'Free space',
  ])
  expect(rowTokens(b, 'Messages')).toEqual(0)
  expect(rowTokens(b, 'Free space')).toEqual(200000 - 54000 - 3000)
  expect(b?.mcp_tools.map(t => t.name)).toEqual(['query', 'search'])
  expect(b?.memory_files.map(f => f.tokens)).toEqual([1500, 900])
})

test('after a turn, Messages is the input tokens minus the fixed rows', async ($, on) => {
  const live = { contextTokens: 54000 as number | null, messagesTokens: 0 }
  const sent = helper(on, undefined, 0, { live })
  const clock = mock.clock(on)
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('turn.complete', () => ({ text: '' }))
  await $.session.start({ cwd: '/work', surface: null, isInteractive: true })
  await clock.settle()
  // The turn's response reports 20k more input than when the count ran.
  live.contextTokens = 54000 + 20000
  await $.turn.complete({ answer: 'ok', durationMs: 10, isAborted: false, reason: 'answer', turnId: 't' })
  const b = breakdowns(sent).at(-1)
  expect(rowTokens(b, 'Messages')).toEqual(20000)
  expect(b?.used_tokens).toEqual(74000)
})

test('a refresh request measures again and empties the request file', async ($, on) => {
  const request = { text: '' }
  const sent = helper(on, undefined, 0, { request })
  const clock = mock.clock(on)
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  await $.session.start({ cwd: '/work', surface: null, isInteractive: true })
  await clock.settle()
  const before = breakdowns(sent).length
  request.text = '{"action":"refresh"}'
  await clock.advance(1000)
  expect(breakdowns(sent).length).toBeGreaterThan(before)
  expect(request.text).toEqual('')
})

test('a compact request compacts once and reports it running, then done', async ($, on) => {
  const request = { text: '' }
  const sent = helper(on, undefined, 0, { request })
  const clock = mock.clock(on)
  let compacts = 0
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('session.compact', () => {
    compacts++
    return { messages: [{ role: 'user' as const, text: 'summary', toolUses: [] }] }
  })
  await $.session.start({ cwd: '/work', surface: null, isInteractive: true })
  await clock.settle()
  request.text = '{"action":"compact"}'
  await clock.advance(1000)
  await clock.advance(1000)
  expect(compacts).toEqual(1)
  const flags = sent.filter(s => 'compacting' in s.payload).map(s => s.payload.compacting)
  expect(flags).toEqual([true, false])
})

test("after a compact, the full count's Messages stands until a newer response", async ($, on) => {
  // Before: 200k of conversation on 54k of fixed rows.
  const live = { contextTokens: 54000 + 200000 as number | null, messagesTokens: 200000 }
  const sent = helper(on, undefined, 0, { live })
  const clock = mock.clock(on)
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('turn.complete', () => ({ text: '' }))
  on('session.compact', () => ({ messages: [{ role: 'user' as const, text: 'summary', toolUses: [] }] }))
  await $.session.start({ cwd: '/work', surface: null, isInteractive: true })
  await clock.settle()
  expect(rowTokens(breakdowns(sent).at(-1), 'Messages')).toEqual(200000)

  // The compact leaves a 4k summary. No response has come back yet, so the
  // input tokens are absent; the full count made now is the true figure.
  live.contextTokens = null
  live.messagesTokens = 4000
  await $.session.compact({ trigger: 'manual', messages: [{ role: 'user', text: 'long history', toolUses: [] }] })
  await clock.settle()
  expect(rowTokens(breakdowns(sent).at(-1), 'Messages')).toEqual(4000)

  // A turn whose usage is still the pre-compact reading must not undo it.
  await $.turn.complete({ answer: 'ok', durationMs: 10, isAborted: false, reason: 'answer', turnId: 'a' })
  expect(rowTokens(breakdowns(sent).at(-1), 'Messages')).toEqual(4000)

  // The next response reports 54k + 6k of input: Messages follows it.
  live.contextTokens = 54000 + 6000
  await $.turn.complete({ answer: 'ok', durationMs: 10, isAborted: false, reason: 'answer', turnId: 'b' })
  expect(rowTokens(breakdowns(sent).at(-1), 'Messages')).toEqual(6000)
})

test('helper runs go one at a time, so a slow one cannot push the next past its timeout', async ($, on) => {
  mock.env(on, { CLAUDE_TERMINAL_HOOK: HELPER, CLAUDE_TERMINAL_STATUS_DIR: '/status' })
  const clock = mock.clock(on)
  let inFlight = 0
  let most = 0
  const order: string[] = []
  on('process.run', async ($, e) => {
    if (e.argv[0] !== HELPER) return run({ exitCode: 0 })
    inFlight++
    most = Math.max(most, inFlight)
    // Each run holds the status lock for 2 s.
    await clock.sleep(2000)
    order.push(JSON.parse(e.init?.stdin ?? '{}').hook_event_name ?? e.argv[1])
    inFlight--
    return run({ exitCode: 0 })
  })
  on('session.id', () => ({ value: 'cc-session' }))
  on('session.cwd', () => ({ value: '/work' }))
  on('tool.call', () => ({ result: { stdout: '' }, isError: false }))
  // Two tool calls at once: four helper runs started together.
  const calls = Promise.all([
    $.tool.call({ tool: 'Bash', tool_use_id: 'p1', command: 'a' }),
    $.tool.call({ tool: 'Bash', tool_use_id: 'p2', command: 'b' }),
  ])
  await clock.advance(10_000)
  await calls
  expect(most).toEqual(1)
  expect(order).toHaveLength(4)
})
