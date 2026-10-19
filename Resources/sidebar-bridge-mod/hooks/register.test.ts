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
function helper(
  on: On,
  gh: Gh = { exitCode: 1, stderr: 'no pull requests found for branch "main"' },
  usageStartedAt = 0,
): Sent[] {
  const sent: Sent[] = []
  mock.env(on, { CLAUDE_TERMINAL_HOOK: HELPER })
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
  on('session.usage', () => ({
    value: {
      startedAt: usageStartedAt,
      context: { tokens: 1000, window: 200000, percent: 1 },
      rateLimits: [],
      cost: { usd: 0.25 },
    },
  }))
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

test('the status line carries model, context and cumulative cost', async ($, on) => {
  const sent = helper(on)
  mock.clock(on, { now: 5000 })
  on('session.measure', ($, e) => ({ changed: e.changed }))
  await $.session.measure({ context: { tokens: 1000, window: 200000, percent: 1 }, rateLimits: [], changed: ['cost'] })
  const line = sent.find(s => s.subcommand === 'statusline')?.payload
  expect(line?.model).toEqual({ id: 'claude-opus-5-5' })
  expect(line?.context_window).toEqual({
    context_window_size: 200000,
    used_percentage: 1,
    remaining_percentage: 99,
    total_input_tokens: 1000,
    total_output_tokens: 0,
    current_usage: { cache_read_input_tokens: 0, cache_creation_input_tokens: 0 },
  })
  // No session.start ran here, so no start time is known yet: duration is 0.
  expect(line?.cost).toEqual({
    total_cost_usd: 0.25,
    total_duration_ms: 0,
    total_api_duration_ms: 0,
    total_lines_added: 0,
    total_lines_removed: 0,
  })
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
    | { context_window: Record<string, unknown>; cost: Record<string, unknown> }
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

test('output tokens sum over turns; cache tokens are the last main turn', async ($, on) => {
  const sent = helper(on)
  mock.clock(on)
  const measure = measured(on)
  on('turn.complete', () => ({ text: '' }))
  const base = { answer: 'ok', durationMs: 10, isAborted: false, reason: 'answer' as const }
  const usage = (out: number, read: number, made: number) => ({
    input_tokens: 5, output_tokens: out, cache_read_input_tokens: read, cache_creation_input_tokens: made, model: 'm',
  })
  await $.turn.complete({ ...base, turnId: 'a', usage: usage(100, 4000, 50) })
  await $.turn.complete({ ...base, turnId: 'b', agentId: 'sub', usage: usage(30, 9999, 9999) })
  await $.turn.complete({ ...base, turnId: 'c', usage: usage(20, 5000, 10) })
  await measure($)
  expect(lastLine(sent)?.context_window).toMatchObject({
    total_output_tokens: 150,
    current_usage: { cache_read_input_tokens: 5000, cache_creation_input_tokens: 10 },
  })
})

test('lines added and removed sum over Edit and Write patches', async ($, on) => {
  const sent = helper(on)
  mock.clock(on)
  const measure = measured(on)
  // Edit: 1 line removed, 3 added. Write of a new file: 2 added.
  const patches: Record<string, unknown> = {
    e1: [{ oldStart: 1, oldLines: 3, newStart: 1, newLines: 5, lines: [' one', '-two', '+two-a', '+two-b', '+two-c', ' three'] }],
    w1: [{ oldStart: 0, oldLines: 0, newStart: 1, newLines: 2, lines: ['+x', '+y'] }],
  }
  on('tool.call', ($, e) => ({ result: { structuredPatch: patches[e.tool_use_id] }, isError: false }))
  await $.tool.call({ tool: 'Edit', tool_use_id: 'e1', file_path: '/a.swift', old_string: 'a', new_string: 'b' })
  await $.tool.call({ tool: 'Write', tool_use_id: 'w1', file_path: '/b.swift', content: 'x' })
  await measure($)
  expect(lastLine(sent)?.cost).toMatchObject({ total_lines_added: 5, total_lines_removed: 1 })
})
