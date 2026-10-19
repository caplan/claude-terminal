/** Whether this process already sent its SessionStart. */
export type SidebarBridgeStarted = boolean

/** Milliseconds of main-loop turn time since the session started. */
export type SidebarBridgeApiMs = number

/** When this process's session began, in $.clock.now() milliseconds. */
export type SidebarBridgeStartedAt = number

/**
 * Figures the status line used to carry and no $ call reports. Output tokens
 * and line counts are running totals; the cache figures are the last main-loop
 * response's, as the status line's current_usage was.
 */
export type SidebarBridgeTotals = {
  outputTokens: number
  cacheReadTokens: number
  cacheCreationTokens: number
  linesAdded: number
  linesRemoved: number
}

declare module 'claude-code' {
  interface PluginState {
    'sidebar-bridge': {
      /** True once this process sent its SessionStart; a hot reload keeps it. */
      started: SidebarBridgeStarted
      /** Summed turn.complete durationMs of the main loop. */
      apiMs: SidebarBridgeApiMs
      /** Set at the first session.start and at /clear. */
      startedAt: SidebarBridgeStartedAt
      /** Token and line figures from turn.complete and file edits. */
      totals: SidebarBridgeTotals
    }
  }
}
