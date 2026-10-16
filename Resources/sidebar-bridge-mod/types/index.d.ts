/** Whether this process already sent its SessionStart. */
export type SidebarBridgeStarted = boolean

/** Milliseconds of main-loop turn time since the session started. */
export type SidebarBridgeApiMs = number

declare module 'claude-code' {
  interface PluginState {
    'sidebar-bridge': {
      /** True once this process sent its SessionStart; a hot reload keeps it. */
      started: SidebarBridgeStarted
      /** Summed turn.complete durationMs of the main loop. */
      apiMs: SidebarBridgeApiMs
    }
  }
}
