import type { On } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'

const HELPER = '/app/Contents/Resources/claude-terminal-hook'

type Sent = { subcommand: string; payload: Record<string, unknown> }

// Stands for the claude-terminal-hook binary: records what the mod sends.
function helper(on: On): Sent[] {
  const sent: Sent[] = []
  mock.env(on, { CLAUDE_TERMINAL_HOOK: HELPER })
  on('process.run', ($, e) => {
    if (e.argv[0] === HELPER) {
      sent.push({ subcommand: e.argv[1] ?? '', payload: JSON.parse(e.init?.stdin ?? '{}') })
    }
    return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('session.id', () => ({ value: 'cc-session' }))
  on('session.cwd', () => ({ value: '/work' }))
  on('session.model', () => ({ value: 'claude-opus-5-5' }))
  on('session.usage', () => ({
    value: {
      startedAt: 0,
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
  })
  expect(line?.cost).toEqual({ total_cost_usd: 0.25, total_duration_ms: 5000, total_api_duration_ms: 0 })
})
