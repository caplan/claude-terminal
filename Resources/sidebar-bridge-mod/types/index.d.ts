/** Whether this process already sent its SessionStart. */
export type SidebarBridgeStarted = boolean

/** Milliseconds of main-loop turn time since the session started. */
export type SidebarBridgeApiMs = number

/** When this process's session began, in $.clock.now() milliseconds. */
export type SidebarBridgeStartedAt = number

/** Lines added and removed this session, which no $ call reports. */
export type SidebarBridgeTotals = {
  linesAdded: number
  linesRemoved: number
}

/** One row of the context breakdown, as /context lists it. */
export type SidebarBridgeContextRow = {
  name: string
  tokens: number
  kind: 'used' | 'free' | 'buffer' | 'deferred'
}

/**
 * The last full /context breakdown: its fixed rows (everything but Messages,
 * Free space and the buffer) and the main context's input tokens when it ran,
 * so later turns can rebuild Messages from their own input tokens.
 */
export type SidebarBridgeBreakdown = {
  rows: SidebarBridgeContextRow[]
  windowTokens: number
  mcpTools: { name: string; server: string; tokens: number }[]
  memoryFiles: { path: string; tokens: number }[]
  measuredAt: number
} | null

declare module 'claude-code' {
  interface PluginState {
    'sidebar-bridge': {
      /** True once this process sent its SessionStart; a hot reload keeps it. */
      started: SidebarBridgeStarted
      /** Summed turn.complete durationMs of the main loop. */
      apiMs: SidebarBridgeApiMs
      /** Set at the first session.start and at /clear. */
      startedAt: SidebarBridgeStartedAt
      /** Line counts from file edits. */
      totals: SidebarBridgeTotals
      /** The last full breakdown; null until one has run. */
      breakdown: SidebarBridgeBreakdown
    }
  }
}
