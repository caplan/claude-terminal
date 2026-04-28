# claude-terminal

Multi-window macOS app wrapping Ghostty's terminal engine, purpose-built for running Claude Code sessions with a live sidebar showing session state, context usage, cost, and tool activity.

Bundle ID: `org.claire.claude-terminal`

## Architecture

AppKit app (not SwiftUI lifecycle) embedding libghostty via GhosttyKit.xcframework.

```
main.swift              → NSApplication.shared.run() + CLI argument parsing
AppDelegate.swift       → window management, menus, session monitors, rename dialog
ContentView.swift       → SwiftUI view: terminal + optional sidebar
SidebarView.swift       → live session sidebar (status, context, cost, tasks, subagents, network)
SidebarHostView.swift   → NSViewRepresentable wrapper giving sidebar its own NSHostingView
SidebarState.swift      → sidebar visibility and resizable width state
SessionMonitor.swift    → watches ~/.claude-terminal/sessions/<id>/status.json via dispatch source
SessionState.swift      → Codable model for session state
MenuBarController.swift → NSStatusItem + NSPanel for the menubar session grid popup
MenuBarPopoverView.swift → SwiftUI grid of session cards shown in the menubar popup
SessionListViewModel.swift → aggregates active + past sessions (scans sessions dir, live updates)
TooltipWindow.swift     → borderless NSPanel for instant card hover tooltips (no clip by popup bounds)
HookInstaller.swift     → installs Claude Code hooks + status line script into ~/.claude settings
JiraTicketDetector.swift → detects Jira ticket from branch name, fetches title via jira CLI
GhosttyTerminalView.swift → 12.6K lines of vendored terminal-engine code (treat as read-only)
GhosttyConfig.swift     → config loading from ~/.config/ghostty/config
Types.swift             → stub types/protocols expected by GhosttyTerminalView (Workspace, TabManager, etc.)
```

### Session monitoring system

Each window launches Claude Code with `CLAUDE_TERMINAL_SESSION_ID` set. Two scripts feed data into `~/.claude-terminal/sessions/<id>/status.json`:

1. **Hook script** (`update-status.sh`) — called on SessionStart, PreToolUse, PostToolUse, Stop, SubagentStart/Stop, TaskCreated/Completed, UserPromptSubmit. Tracks status, current tool, subagents, tasks, tool call latency. Clears `activeTools` on Stop and UserPromptSubmit. Subagents are removed only by their own `SubagentStop` (so background agents survive across turns); `SessionStart` is the cold reset.
2. **Status line script** (`statusline.sh`) — polled every 3s by Claude Code. Merges context window, cost, model name, session name, derived network metrics.

`SessionMonitor` watches the JSON file via `DispatchSource` and decodes changes into `@Published var state`.

### Portal system (critical to understand)

GhosttyTerminalView is an NSViewRepresentable that returns an empty HostContainerView placeholder. The actual terminal view (GhosttySurfaceScrollView) is added later by `TerminalWindowPortalRegistry.bind()`, which calls `host.addSubview(hostedView)` with autolayout constraints. If bind() is a no-op, the window renders black.

### Key singletons

- `GhosttyApp.shared` — initializes the Ghostty C runtime (ghostty_init, ghostty_config_new, ghostty_app_new)
- `AppDelegate.shared` — window management, menu bar, session monitors, stub methods that satisfy GhosttyTerminalView's expected host API

## Features

- Multi-window with Window menu for switching between sessions (Cmd+1-9)
- Sidebar with live status card (header tints by state: yellow=thinking, blue=tool, green=streaming)
- Current tool shown with human-readable verb and detail (file path, command, etc.)
- Subagent tool badges in sidebar
- Subagent tool details shown in sidebar (file path, command, search query, etc.)
- Right-click subagent to Force Quit (hides from sidebar via hidden-agents file)
- Background subagents stay in sidebar across turns (removed only by their own `SubagentStop` or a new session)
- Parallel tool calls shown simultaneously in status card
- API latency card with last/avg/API% metrics (bottom-anchored, measures actual API round-trip time)
- Context, cost, and API latency cards auto-collapse to single-line summaries when window is short (collapse order: API latency first, then cost, then context)
- Task dependency visualization: topological sort, indentation, lock icon for blocked tasks
- Animated spinning icon on in-progress tasks
- Documents section: persistent clickable links to .md files Claude writes during the session (right-click for Open With, Show in Finder, Copy Path; excludes memory files)
- Clickable file paths in tool detail (opens in default app when file exists on disk)
- Jira ticket title fetched and shown with wrapping text below ticket key
- Working directory shown in sidebar header (abbreviated with ~)
- Native macOS notifications when Claude needs input (toggle in Settings)
- Directory picker always shown with session name, "New session", and "Live dangerously" options; the "Live dangerously" choice is remembered per directory (stored in UserDefaults `dangerDirs`) and auto-checked when you reselect that folder
- `--continue` is the default; sessions always resume where you left off unless "New session" is checked
- If `--continue` fails (no prior session), automatically retries without it to start fresh
- CLI re-invocation opens a new window in the running app (via URL scheme), works with or without arguments
- CLI launcher: `claude-terminal [--name NAME] [directory] [-- claude-args...]`
- Window size/position remembered per session name
- Session rename persists across app restarts (stored in UserDefaults by working directory)
- Rename sessions via View > Rename Session (Cmd+Shift+R) or pencil icon in sidebar
- Toggle sidebar via View > Toggle Sidebar (Cmd+B)
- Model name updates live when changed via /model
- Copy/paste works cross-app
- Custom app icon
- Uninstall via menu or scripts/uninstall.sh
- Window closes automatically when Claude exits
- Terminal runs claude via login shell (`$SHELL -l`) with `initialInput` so user dotfiles are sourced
- Full user shell environment captured at startup and injected into terminal sessions
- Save/restore windows on quit with `--continue` added automatically
- Jira ticket detection from branch name or `.jira-ticket` file, clickable link in sidebar
- Jira CLI support for both ankitpokhrel/jira-cli and go-jira
- Resizable sidebar (drag edge, width persisted across sessions, 220-500pt range)
- CLI symlink installed to `~/.local/bin/claude-terminal` (no admin privileges)
- Menubar icon with session grid popup: hover or click (configurable) to show all sessions — both currently open windows and recent sessions scanned from `~/.claude-terminal/sessions/` (deduped by working directory, newest first). Cards show favicon-derived background color (dominant hue desaturated + shifted for readability), session name, directory (middle-truncated), status, cost. Hovering a card shows an instant tooltip in its own NSPanel (not clipped by popup bounds) with full name + full path. Click an active card to focus the window; click a recent card to reopen. Right-click a recent (non-active) card to hide it from the menu or delete the project folder from disk (hidden dirs stored in UserDefaults `hiddenSessionDirs`). Preference: Settings > Menu Bar (visibility + click/hover trigger)

## Build

Requires Xcode. No zig or ghostty source checkout needed — the build script downloads a prebuilt `GhosttyKit.xcframework` release asset keyed by a pinned commit SHA.

```bash
# First time: fetch GhosttyKit.xcframework (downloads ~132MB, verifies SHA-256)
./scripts/ensure-ghosttykit.sh

# Generate xcodeproj (if project.yml changed)
xcodegen generate

# Build
xcodebuild -project claude-terminal.xcodeproj -scheme claude-terminal -configuration Release build

# Copy to wherever you like
cp -R ~/Library/Developer/Xcode/DerivedData/claude-terminal-*/Build/Products/Release/claude-terminal.app /Applications/ && codesign --force --deep --sign - /Applications/claude-terminal.app
```

### GhosttyKit dependency

`scripts/ensure-ghosttykit.sh` downloads `GhosttyKit.xcframework.tar.gz` from the upstream ghostty release pipeline (`github.com/manaflow-ai/ghostty/releases/tag/xcframework-<sha>`), verifies the SHA-256 against `scripts/ghosttykit-checksums.txt`, extracts to `~/.cache/claude-terminal/ghosttykit/<sha>/`, and symlinks `GhosttyKit.xcframework` into the project root. To bump ghostty: update `scripts/ghostty.version` with the new SHA and add a matching line to `scripts/ghosttykit-checksums.txt`.

## Source lineage

- `GhosttyTerminalView.swift` — vendored terminal-engine code, ~12.6K lines. Treat as read-only.
- `GhosttyConfig.swift` — vendored, unmodified.
- `Types.swift` — ~660 lines of stub types/protocols that GhosttyTerminalView imports (Workspace, TabManager, Panel, Notification, Split, etc.). Neutralizes unused infrastructure.
- `main.swift`, `AppDelegate.swift`, `ContentView.swift`, `SidebarView.swift`, `SessionMonitor.swift`, `SessionState.swift`, `HookInstaller.swift` — written from scratch for claude-terminal.

## Conventions

- Don't modify GhosttyTerminalView.swift unless necessary — it's 12.6K lines of working terminal code. Add stubs to Types.swift or AppDelegate.swift instead.
- When adding stubs, match the exact signatures GhosttyTerminalView.swift expects (argument labels, return types, default values).
- AppKit lifecycle via main.swift, not SwiftUI @main — the SwiftUI lifecycle doesn't reliably call applicationDidFinishLaunching.
- NSHostingView with explicit frame, not NSHostingController — the controller collapses to 1x32px because GhosttyTerminalView has zero intrinsic size.
- SidebarView must live in its own NSHostingView (via SidebarHostView), not as a sibling of GhosttyTerminalView in the same SwiftUI tree. The Metal renderer prevents SwiftUI from invalidating sibling views.
- Hook/status line scripts are embedded as string literals in HookInstaller.swift with a VERSION comment for upgrade detection.

## Versioning

Stay on 0.x releases. Do not create 1.x tags or releases yet.

## Known dead code

GhosttyTerminalView.swift still contains code for splits, notifications, image transfers, tmux layout, drag-and-drop panes, and other features the vendored engine supports but this app doesn't use. They're neutralized by stub types in Types.swift but not removed. A future cleanup pass could strip ~3-4K lines and the corresponding stubs.
