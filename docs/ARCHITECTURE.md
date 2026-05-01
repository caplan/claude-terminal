# Architecture

## Overview

claude-terminal is a multi-window macOS AppKit application that embeds Ghostty's terminal engine via `GhosttyKit.xcframework`. Each window runs one Claude Code session with a live SwiftUI sidebar. A small compiled helper binary handles Claude Code's hook + statusLine integration.

Bundle ID: `org.claire.claude-terminal`.

## Source layout

```
main.swift                  → NSApplication.shared.run() + CLI argument parsing
AppDelegate.swift           → window management, menus, session monitors, URL scheme
ContentView.swift           → SwiftUI root: tab bar + terminal + sidebar
SidebarView.swift           → live session sidebar (status, docs, context, cost, tasks, subagents, network)
SidebarHostView.swift       → NSViewRepresentable that gives the sidebar its own NSHostingView
SidebarState.swift          → sidebar visibility + resizable width
SessionMonitor.swift        → watches ~/.claude-terminal/sessions/<id>/status.json via DispatchSource
SessionState.swift          → Codable model for session state
DocumentTabState.swift      → per-window markdown-tab model (open/close/find/zoom)
DocumentExcerptCache.swift  → caches first-heading / first-line for sidebar doc cards
MarkdownViewerView.swift    → WKWebView wrapper for the inline markdown tab
DocFindBar.swift            → in-tab Cmd+F find overlay
TerminalTabBar.swift        → compact per-window tab bar
MenuBarController.swift     → NSStatusItem + NSPanel for the menu-bar session grid
MenuBarPopoverView.swift    → SwiftUI grid of session cards for the menu-bar popup
SessionListViewModel.swift  → aggregates active + past sessions (live updates)
TooltipWindow.swift         → borderless NSPanel for instant card hover tooltips
HookInstaller.swift         → writes Claude Code hook + statusLine entries into ~/.claude/settings.json
JiraTicketDetector.swift    → detects Jira ticket from branch name, fetches title via jira CLI
FaviconLoader.swift         → derives a project favicon from the working directory
PreferencesView.swift       → Settings window
ThemeCatalog.swift          → built-in Ghostty theme metadata
GhosttyTerminalView.swift   → 12.6K lines of vendored terminal-engine code (read-only)
GhosttyConfig.swift         → config loading from ~/.config/ghostty/config
GhosttyConfigFile.swift     → vendored config parser
Types.swift                 → stub types/protocols expected by GhosttyTerminalView
Hook/main.swift             → claude-terminal-hook helper binary (hook + statusline subcommands)
```

## Session monitoring

Each window launches Claude Code with `CLAUDE_TERMINAL_SESSION_ID` set. The per-window state lives in `~/.claude-terminal/sessions/<uuid>/status.json`, written by two entry points into the helper binary (`Sources/Hook/main.swift`):

1. **`claude-terminal-hook hook`** — invoked on `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`, `SubagentStart`, `SubagentStop`, `TaskCreated`, `TaskCompleted`, `Notification`. Tracks status, current tool, active subagents, tasks, and tool-call latency. Clears `activeTools` on `Stop` and `UserPromptSubmit`. Subagents are removed only by their own `SubagentStop` so background agents survive across turns; `SessionStart` is the cold reset for everything *except* `documents` (which are sticky).

2. **`claude-terminal-hook statusline`** — Claude Code polls this every 3s. Merges context window, cumulative cost, model name, and derived network metrics.

`SessionMonitor` (`Sources/SessionMonitor.swift`) watches the JSON file via `DispatchSource` and decodes changes into `@Published var state`. It also merges hook-reported docs with the persisted per-working-dir list (`~/.claude-terminal/docs-by-dir.json`), filters out files that no longer exist, and persists the union.

Concurrency: the hook script and the Swift side both write `status.json`. Atomicity comes from acquiring an `flock(LOCK_EX)` on a sibling `.status.lock` file for the read-modify-write, then a POSIX `rename(2)` from a temp file (`FileManager.moveItem` silently drops the overwrite, so `rename(2)` is the correct primitive).

## Cost accounting

`cost.total_cost_usd` coming from Claude Code's statusLine payload is **cumulative for the session**, including prior runs when resumed with `--continue`. We pass it through as-is — no baseline addition, no summation on our side. See `Hook/main.swift:runStatusLine`. A per-session snapshot is written to `~/.claude-terminal/cost-by-session.json` keyed by Claude Code's `session_id`, used purely to seed the sidebar with the last-known value before the first poll arrives on reopen.

## Portal system (critical)

`GhosttyTerminalView` is an `NSViewRepresentable` that returns an **empty** `HostContainerView` placeholder. The actual terminal view (`GhosttySurfaceScrollView`) is added later by `TerminalWindowPortalRegistry.bind()`, which calls `host.addSubview(hostedView)` with autolayout constraints. If `bind()` is a no-op, the window renders black.

This is why `ContentView` keeps the terminal view mounted even when a markdown tab is active (opacity 0, hit-testing off) instead of removing it from the view tree — detaching the host would drop the portal binding.

## Inline markdown viewer

- Bundled in `Resources/markdown-viewer/`: `viewer.html` + `viewer.css` + vendored `marked.min.js`, `highlight.min.js`, `mermaid.min.js`, `purify.min.js`, `github-markdown.css`.
- `MarkdownViewerView` wraps a `WKWebView`. `makeNSView` loads `viewer.html` via `loadFileURL(_:allowingReadAccessTo:)` against the bundle subdirectory; each subsequent file is rendered by JSON-encoding the source text and calling `window.render(src)` via `evaluateJavaScript`.
- Auto-reload: the Coordinator owns a `DispatchSource` watching the file for `[.write, .rename, .delete, .extend]`. Rename events trigger a re-attach after a 100 ms debounce (Claude edits via atomic rename).
- Heading anchor links work because the JS harness slugifies `<h*>` nodes post-sanitize and intercepts `href="#..."` clicks.
- Mermaid diagrams get per-diagram pan (drag), zoom (⌘+scroll around cursor), and reset (double-click), plus a hover hint — implemented in `viewer.html` without an external library.
- Scroll position is live-tracked by a throttled scroll listener that posts to a `WKScriptMessageHandler` named `"scroll"`; values end up in `DocumentTabState.liveScroll`. Session restore re-injects saved `scrollY` via `window.setScroll(y)` after the first render.
- Cmd+F is wired through `DocumentTabState.findActive` + `DocumentTabState.findQuery`; `DocFindBar` overlays the active tab and calls `WKWebView.find(_:configuration:)`.

## Document persistence

- `~/.claude-terminal/docs-by-dir.json` — dictionary of `workingDirectory → [mdPath]`. Populated by hook events for any `file_path` / `notebook_path` ending in `.md` / `.markdown` / `.mdown`, and by explicit user actions (drag-drop onto sidebar, `open -a claude-terminal foo.md`, sidebar card clicks).
- On launch, `AppDelegate.pruneStaleFiles` drops entries whose working directory no longer exists and prunes missing-file paths from remaining entries.
- On window open, `SessionMonitor` seeds `state.documents` from the persist file for this session's working directory.

## Key singletons

- `GhosttyApp.shared` — initialises the Ghostty C runtime (`ghostty_init`, `ghostty_config_new`, `ghostty_app_new`).
- `AppDelegate.shared` — window management, menu bar, session monitors, plus stub methods that satisfy the host API `GhosttyTerminalView` expects.

## Source lineage

- `GhosttyTerminalView.swift` — vendored from Ghostty's macOS app, ~12.6K lines. Treat as read-only.
- `GhosttyConfig.swift`, `GhosttyConfigFile.swift` — vendored, unmodified.
- `Types.swift` — ~660 lines of stub types/protocols that `GhosttyTerminalView` imports (`Workspace`, `TabManager`, `Panel`, `Notification`, `Split`, etc.). Neutralises unused infrastructure.
- `main.swift`, `AppDelegate.swift`, `ContentView.swift`, the `Sidebar*.swift` family, `SessionMonitor.swift`, `SessionState.swift`, `HookInstaller.swift`, `Hook/main.swift`, the document-viewer stack — written from scratch for claude-terminal.

## Conventions

- Don't modify `GhosttyTerminalView.swift` unless necessary. Add stubs to `Types.swift` or host methods to `AppDelegate.swift` instead.
- When adding stubs, match the exact signatures `GhosttyTerminalView.swift` expects (argument labels, return types, default values).
- AppKit lifecycle via `main.swift`, **not** SwiftUI `@main` — the SwiftUI lifecycle doesn't reliably call `applicationDidFinishLaunching`.
- `NSHostingView` with an explicit frame, **not** `NSHostingController` — the controller collapses to 1×32 px because `GhosttyTerminalView` has zero intrinsic size.
- `SidebarView` must live in its own `NSHostingView` (via `SidebarHostView`), **not** as a sibling of `GhosttyTerminalView` in the same SwiftUI tree. The Metal renderer prevents SwiftUI from invalidating sibling views.
- Prefer POSIX `rename(2)` over `FileManager.moveItem` for atomic replacement — `moveItem` fails silently when the destination exists.
- Any cross-process mutation of `status.json` must `flock(LOCK_EX)` on `.status.lock` first.

## Known dead code

`GhosttyTerminalView.swift` still contains code for splits, notifications, image transfers, tmux layout, drag-and-drop panes, and other features the vendored engine supports but this app doesn't use. They're neutralised by stub types in `Types.swift` but not removed. A future cleanup pass could strip ~3–4K lines and the corresponding stubs.
