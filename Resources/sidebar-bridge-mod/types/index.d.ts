/** Whether this process already sent its SessionStart. */
export type SidebarBridgeStarted = boolean

/** Milliseconds of main-loop turn time since the session started. */
export type SidebarBridgeApiMs = number

/** When this process's session began, in $.clock.now() milliseconds. */
export type SidebarBridgeStartedAt = number

/** One row of the context breakdown, as /context lists it. */
export type SidebarBridgeContextRow = {
  name: string
  tokens: number
  kind: 'used' | 'free' | 'buffer' | 'deferred'
}

/**
 * The last full /context breakdown: its fixed rows (everything but Messages,
 * Free space and the buffer), its own Messages count, and the main context's
 * input tokens when it ran. Until a newer response reports other input tokens,
 * the full count's Messages stands; after one, Messages is rebuilt from it.
 */
export type SidebarBridgeBreakdown = {
  rows: SidebarBridgeContextRow[]
  messagesTokens: number
  inputTokensAtMeasure: number | null
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
      /** The last full breakdown; null until one has run. */
      breakdown: SidebarBridgeBreakdown
    }
  }
}
