# Architecture

## Overview

claude-terminal is a multi-window macOS AppKit application that embeds Ghostty's terminal engine via `GhosttyKit.xcframework`. Each window runs one Claude Code session with a live SwiftUI sidebar. A Claude Code mod, loaded into each session, feeds the sidebar through a small compiled helper binary.

Bundle ID: `org.claire.claude-terminal`.

## Source layout

```
main.swift                  → NSApplication.shared.run() + CLI argument parsing
AppDelegate.swift           → window management, menus, session monitors, URL scheme
ContentView.swift           → SwiftUI root: tab bar + terminal + doc/image tabs + sidebar
SidebarView.swift           → live session sidebar (status, activity chart, docs, context, cost, tasks, subagents, github status)
SidebarHostView.swift       → NSViewRepresentable that gives the sidebar its own NSHostingView
SidebarState.swift          → sidebar visibility + resizable width
SessionMonitor.swift        → watches ~/.claude-terminal/sessions/<id>/status.json via DispatchSource
SessionState.swift          → Codable model for session state
TranscriptTailer.swift      → tails ~/.claude/projects/<sanitized>/<cc-session>.jsonl to surface assistant prose + background-task notifications
GitHubStatusMonitor.swift   → singleton that polls githubstatus.com every 30s with a 500ms timeout + GitRepoDetector
DocumentTabState.swift      → per-window doc-tab model (open/close/find/zoom, md + image)
DocumentExcerptCache.swift  → caches first-heading / first-line for sidebar markdown cards
MarkdownViewerView.swift    → WKWebView wrapper for the inline markdown tab
ImageViewerView.swift       → NSScrollView + NSImageView tab for viewing images; auto-reloads on write
DocFindBar.swift            → in-tab Cmd+F find overlay
TerminalTabBar.swift        → compact per-window tab bar
MenuBarController.swift     → NSStatusItem + NSPanel for the menu-bar session grid
MenuBarPopoverView.swift    → SwiftUI grid of session cards for the menu-bar popup
SessionListViewModel.swift  → aggregates active + past sessions (live updates)
TooltipWindow.swift         → borderless NSPanel for instant card hover tooltips
ClaudeCodeIntegration.swift → requires Claude Code 2.1.301+, builds each session's mod environment
LegacyHookCleanup.swift     → removes the settings.json entries and scripts older versions installed
JiraTicketDetector.swift    → detects Jira ticket from branch name, fetches title via jira CLI
FaviconLoader.swift         → derives a project favicon from the working directory
PreferencesView.swift       → Settings window
PreferencesWindowController.swift → NSWindowController for the Settings panel
Updater.swift               → Sparkle auto-update wiring
ThemeCatalog.swift          → built-in Ghostty theme metadata
GhosttyTerminalView.swift   → 12.6K lines of vendored terminal-engine code (read-only)
GhosttyConfig.swift         → config loading from ~/.config/ghostty/config
GhosttyConfigFile.swift     → vendored config parser
Types.swift                 → stub types/protocols expected by GhosttyTerminalView
Hook/main.swift             → claude-terminal-hook helper binary (hook + statusline subcommands)
```

`Resources/sidebar-bridge-mod/` holds the Claude Code mod each session loads (a TypeScript hooks module, its state contract and its tests).

## Session monitoring

Each window launches Claude Code with `CLAUDE_TERMINAL_SESSION_ID` set and the bundled `sidebar-bridge` mod loaded through `CLAUDE_CODE_PLUGIN_DIRS`. The app writes nothing to `~/.claude/settings.json`. At launch it runs `claude --version` and will not open a session on a build older than `ClaudeCodeVersion.minimum`, because the mod needs that build's events.

### The sidebar-bridge mod

The mod (`Resources/sidebar-bridge-mod/hooks/register.ts`) turns Claude Code's native function-hook events into the stdin JSON of the classic hooks, and runs the helper binary with it through `$.process.run`. The helper's handlers therefore stay keyed by the classic names:

| Native event | Sent as |
|---|---|
| `session.start` (first per process) | `SessionStart`, `source: startup` |
| `session.end` with `reason: clear` | `SessionStart`, `source: clear` |
| `prompt.submit` from the person (`origin.kind` `composer` or `bridge`) | `UserPromptSubmit` |
| `tool.call`, before and after `next` | `PreToolUse`, then `PostToolUse` or `PostToolUseFailure` |
| `tool.call` of `TaskCreate`, from its result | `TaskCreated` |
| `agent.spawn`, from its answer | `SubagentStart` |
| `turn.complete` | `Stop` on the main loop, `SubagentStop` with `agentId` |
| `tool.check` with `ask`, still unanswered after 4 s | `Notification`, `permission_prompt` |
| `session.measure`, plus a 3 s timer | the `statusline` payload, from `$.session.usage()` |
| `gh pr view`, every 60 s and after a Bash call whose result reports a PR, push or branch change | the `statusline` payload's `pr` block |
| `$.session.usage({ breakdown: 'full' })` at session start, after a compact and on Refresh; rebuilt after each turn | the `statusline` payload's `context_breakdown` |

Every helper run takes the `flock` on `.status.lock`, so runs finish one at a time. The mod therefore chains its runs (`send` waits for the one before it), and the 3 s poll skips a tick while the last one is still pending. Without that, runs started faster than they finish queued on the lock, and the last in line passed its 5 s timeout and was killed.

The mod hooks no `classic.*` event. On machines with managed settings, and for Team and Enterprise organizations, the built-in `cc-plugin-sec-default` plugin skips user-tier plugins on those events.

Two choices need care:

- **The ask wait.** `tool.check` reports `ask` before the permission mode settles it. In auto mode the classifier then answers in about 1.5 s with no dialog. No native event reports the dialog itself, and no settings file reliably names the mode. So the mod waits 4 s, and the `tool.call` hook cancels the wait once the call is answered.
- **State that must survive a hot reload.** A reload runs `register` and `session.start` again. The "already started" flag and the summed turn time therefore live in `$.state` (contract: `types/index.d.ts`). Module variables would reset.

Some statusLine figures have no `$` call, so the mod keeps them in `$.state`:

- **Duration** counts from this process's first `session.start` (and from `/clear`). `usage.startedAt` is a resumed session's *first* launch, so with `--continue` it reported days.

### Context breakdown, Refresh and Compact

The Context card shows the percent used and a stacked bar. A **Details** disclosure, closed by default, holds the `/context` breakdown: one row per category, and the MCP tools and memory files behind two of them. Its open or closed state is one preference for every window (`contextDetailsExpanded`). A full count sends about one token-count API request per tool and memory file, so the mod runs one only at session start, after a compact, and when the person presses **Refresh**. Between those the fixed rows (tools, skills, memory, system prompt) hold. After each turn the mod rebuilds Messages from the main context's input tokens (`usage.context.tokens`) minus those fixed rows, which costs no request.

A compact is the exception. Right after one, no response has come back, so `usage.context.tokens` is absent or still the pre-compact reading, and only the full count made then has the true Messages. The mod stores that count's Messages and the input tokens it saw, and keeps the full count's figure until a response reports different input tokens.

The app cannot call into a session, so the buttons go through a file. Refresh and **Compact session** write `{"action": "refresh" | "compact"}` to `mod-request.json` in the session's status directory (`CLAUDE_TERMINAL_STATUS_DIR`). The mod polls it once a second and empties it when it takes the request (`$.fs` has no delete). Compact runs `$.session.compact()` and sends `compacting: true`, then `false`, so the sidebar can disable the buttons while it runs.

No native source gives Claude Code's own session name (`/rename`) or the permission mode, so the sidebar shows neither. The window title still comes from the app and from your own renames. The pull request comes from `gh` instead: the mod runs `gh pr view` in the session's directory. When `gh` is missing, signed out or offline, the mod sends nothing and the card keeps the last PR it showed. TaskCompleted has no native event either: a task's status still updates through the `TaskUpdate` tool input that `PreToolUse` carries.

The helper binary (`Sources/Hook/main.swift`) has two entry points:

1. **`claude-terminal-hook hook`** tracks status, current tool, active subagents, tasks, and tool-call latency. It clears `activeTools` on `Stop` and `UserPromptSubmit`. Subagents are removed only by their own `SubagentStop`, so background agents survive across turns. `SessionStart` is the cold reset for everything *except* `documents` (which are sticky).

2. **`claude-terminal-hook statusline`** merges context window, cumulative cost, model name, and derived network metrics.

`SessionMonitor` (`Sources/SessionMonitor.swift`) watches the JSON file via `DispatchSource` and decodes changes into `@Published var state`. It also merges hook-reported docs with the persisted per-working-dir list (`~/.claude-terminal/docs-by-dir.json`), filters out files that no longer exist, and persists the union.

Concurrency: the helper binary and the Swift side both write `status.json`. Atomicity comes from acquiring an `flock(LOCK_EX)` on a sibling `.status.lock` file for the read-modify-write, then a POSIX `rename(2)` from a temp file (`FileManager.moveItem` silently drops the overwrite, so `rename(2)` is the correct primitive).

Retention: `~/.claude-terminal/sessions/<uuid>/` directories accumulate so the menu-bar popover can list past sessions across runs. `AppDelegate.pruneStaleFiles` (launch-time) keeps the newest 100 dirs modified within 30 days, and additionally removes any dir whose recorded `workingDirectory` has been deleted on disk. The popover (`SessionListViewModel.scanPastSessions`) also filters out missing-cwd entries at read time so deleted projects disappear immediately, before the next launch's prune. The same launch prune keeps the newest 10 MetricKit reports in `diagnostics/`, deletes a leftover `debug.log` in a Release build with `CT_DEBUG_LOG` unset, removes `*.sb-*` temp files older than an hour (interrupted atomic writes), and halves `~/Library/Logs/claude-terminal-exits.log` once it passes 256 KB.

### Hook diagnostics

Every hook invocation writes stage breadcrumbs to `~/.claude-terminal/hook.log` via `fsync` so the trail survives SIGKILL / SIGSEGV. Each line is `HH:MM:SS.mmm [<8-char-session>] <event>`, covering entry, lock acquisition, state I/O, and exit. This exists because Claude Code reports hook failures as "non-blocking status code: no stderr output" — kernel signal-kills bypass stdio flushing, so stderr alone isn't reliable. The hook deliberately does **no** file-system walking in its own process (earlier attempts to scan cwd for Bash-produced images repeatedly SIGKILLed on slow volumes); the only `fileExists` calls it makes are on explicit `file_path` / `notebook_path` values from tool input.

## Transcript tailer

`TranscriptTailer` (`Sources/TranscriptTailer.swift`) watches the Claude Code JSONL at `~/.claude/projects/<sanitized-cwd>/<ccSessionId>.jsonl` via `DispatchSource` and emits a coalesced `TranscriptSnapshot` to `SessionMonitor` whenever anything changes. It extracts:

- **Latest assistant prose** — surfaced as the italic headline above the tool card. Inline markdown is parsed via `AttributedString(markdown:)` so `**bold**` / `*italic*` / `` `code` `` render with real styling instead of literal punctuation.
- **Background-task notifications** — `<task-notification>` user-message payloads are detected by content-string inspection (not shape), and the `<summary>` XML field is extracted and pushed to `recentTexts` + `latestText`. That's how "Background command *X* completed" from Claude Code's TUI mirrors into the sidebar.
- **Per-turn tool count + error count + duration** — read from `system/turn_duration` events.

`resetTurn()` on a real user prompt clears `latestText`/`recentTexts` so the next turn starts fresh. `isUserPrompt()` distinguishes real prompts (string content OR no `tool_result` blocks) from tool-result user entries so mid-turn tool results don't trigger the reset.

## Activity chart

The Activity section of the sidebar is a CPU-style bidirectional bar graph driven entirely by Swift-side sampling (the hook is **not** involved beyond providing `state.status` + `state.activeTools`):

- **10 Hz sub-sampler** — `Timer.publish(every: 1.0/10.0, …)` attached to the root sidebar view. Each tick reads the current `state.status` and `activeTools`, updates streak counters, and accumulates sub-samples.
- **3-second bars** — every 30 sub-ticks one `ActivitySample` is emitted with `claude` / `tool` ∈ [0, 1] (fraction of the second the bucket was busy). Ring buffer capped at `activityWindow + 1 = 61` so one bar always lives offscreen-right, sliding in over the following 3 seconds.
- **Horizontal slide animation** — a `TimelineView` computes `progress = timeSinceLastSample / 3s` and offsets the whole bar HStack by `-pitch * progress`. When a new sample is emitted the offset resets to 0 and the array shifts, producing a continuous scroll.
- **Freeze gate (load-bearing, do not remove)** — the chart is hosted in the sidebar's `NSHostingView`, so a per-frame redraw forces a recursive AppKit layout pass of that subtree on every Core Animation update cycle. A naïve `TimelineView(.animation)` ticks at 30 fps *forever* while on screen, and the 10 Hz timer keeps emitting zero samples + moving `lastSampleTime`, so an idle session perpetually relays out the hosted tree — the exact main-thread CPU-resource exception MetricKit filed repeatedly (≤ v0.42.8). The slide therefore runs through a custom `ActivitySlideSchedule(animating:)`: dense 30 fps only while *live* (real Claude/tool work, or the last burst still within its `barDurationSecs` slide window), otherwise a single static frame and stop. Once idle the sub-sampler early-returns with **zero `@State` mutation** (no invalidation); the session resuming republishes `state`, which re-evaluates `body`, recreates the schedule `animating: true`, and it ticks again (≤ one timer interval latency).
- **Bidirectional layout** — each column is a VStack with two `ZStack(alignment: .bottom)` / `.top` halves, so partial bars always anchor to the horizontal centerline.
- **Colour ramp** — light-blue → yellow → orange → red, interpolated linearly in RGB from a 5-stop gradient keyed on `streakSecs / intensityMaxSecs` (peak red at 1800 s = 30 min). The Claude streak resets on idle; the Tool streak resets whenever a new tool ID appears in `activeTools`. The tool bar also gets a 1-px left inset on the first bar of a fresh tool run.
- **Mutually exclusive buckets** — `claudeBusy` requires `!toolBusy`, so a short tool caught by the `toolMsTotal` delta path doesn't also credit Claude.
- **Tooltip** — each sample tracks the distinct tool names seen during its window; the tool rectangle has a `.help()` showing them.

## GitHub status

`GitHubStatusMonitor.shared` is a singleton `ObservableObject` that polls `https://www.githubstatus.com/api/v2/status.json` every 30 seconds on an ephemeral `URLSession` with `timeoutIntervalForRequest = 0.5` / `timeoutIntervalForResource = 1.0`. It publishes `(indicator, summary)` — on any network / parse failure it falls back to `indicator: .unknown` with empty summary.

Every `SidebarView` references `.shared` via `@ObservedObject`, so all windows share one network call.

A small template-rendered GitHub octocat SVG (`Resources/Assets.xcassets/github.imageset`) appears next to the working-directory line **only when** (a) `GitRepoDetector.isInGitRepo(cwd)` (walks up from cwd looking for `.git`, cached by path) and (b) indicator ∉ {`none`, `unknown`}. Tint colour encodes severity: yellow / orange / red / blue. Click opens `status.github.com`. Hover uses `InstantTooltip` (custom SwiftUI modifier) rather than `.help()` to avoid the ~1-2 s system tooltip delay; the popover uses `NSColor.textBackgroundColor` to stay truly opaque over the sidebar's vibrancy material.

## Cost accounting

`cost.total_cost_usd` in the statusline payload (from `$.session.usage().cost.usd`) is **cumulative for the entire CLI lifetime** — it spans `--continue` resumes *and* `/clear`. We pass it through as-is on every poll except after `/clear`: when the SessionStart hook fires with `source: "clear"`, it stamps `_pendingCostReset` on `state`. The next `runStatusLine` consumes that flag, snapshots the current cumulative report into `_costBaseline`, and subsequent polls compute `displayed = reported - baseline` per-field. The baseline lives in `state` (status.json), so it persists across reopen; the persist file at `~/.claude-terminal/cost-by-session.json` therefore stores the post-baseline value, which is exactly what the sidebar wants to seed on reopen. Subtraction only — never sum a saved value on top of Claude Code's number; that path doubled cost on save+quit+relaunch (commit 0403696). See `Hook/main.swift:runStatusLine` and `handleSessionStart`.

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

- `~/.claude-terminal/docs-by-dir.json` — dictionary of `workingDirectory → [path]`. Populated by hook events for any `file_path` / `notebook_path` with a viewable extension (markdown: `.md` / `.markdown` / `.mdown`; images: `.png` / `.jpg` / `.jpeg` / `.gif` / `.bmp` / `.tiff` / `.webp` / `.heic` / `.heif` / `.svg` / `.ico` / `.avif`), and by explicit user actions (drag-drop onto sidebar, `open -a claude-terminal foo.md`, sidebar card clicks).
- `ViewableDocument.isImage(_:)` / `.isMarkdown(_:)` (in `ImageViewerView.swift`) gate which viewer renders each tab. Doc cards in the sidebar dispatch on the same predicate — markdown cards show a first-heading excerpt via `DocumentExcerptCache`; image cards render an async NSImage thumbnail.
- On launch, `AppDelegate.pruneStaleFiles` drops entries whose working directory no longer exists and prunes missing-file paths from remaining entries.
- On window open, `SessionMonitor` seeds `state.documents` from the persist file for this session's working directory.
- **Not tracked**: files produced by Bash commands (e.g. `python plot.py` writing `out.png`). Previous hook implementations that scanned `cwd` post-Bash caused PostToolUse:Bash SIGKILLs on slow volumes, so the hook no longer does any FS walking. A future out-of-process FSEvents watcher in the Swift app could fill this gap without risking hook timeouts.

## Key singletons

- `GhosttyApp.shared` — initialises the Ghostty C runtime (`ghostty_init`, `ghostty_config_new`, `ghostty_app_new`).
- `AppDelegate.shared` — window management, menu bar, session monitors, plus stub methods that satisfy the host API `GhosttyTerminalView` expects.

## Source lineage

- `GhosttyTerminalView.swift` — vendored from Ghostty's macOS app, ~12.6K lines. Treat as read-only.
- `GhosttyConfig.swift`, `GhosttyConfigFile.swift` — vendored, unmodified.
- `Types.swift` — ~660 lines of stub types/protocols that `GhosttyTerminalView` imports (`Workspace`, `TabManager`, `Panel`, `Notification`, `Split`, etc.). Neutralises unused infrastructure.
- `main.swift`, `AppDelegate.swift`, `ContentView.swift`, the `Sidebar*.swift` family, `SessionMonitor.swift`, `SessionState.swift`, `ClaudeCodeIntegration.swift`, `Hook/main.swift`, the sidebar-bridge mod, the document-viewer stack — written from scratch for claude-terminal.

## Conventions

- Don't modify `GhosttyTerminalView.swift` unless necessary. Add stubs to `Types.swift` or host methods to `AppDelegate.swift` instead.
- When adding stubs, match the exact signatures `GhosttyTerminalView.swift` expects (argument labels, return types, default values).
- AppKit lifecycle via `main.swift`, **not** SwiftUI `@main` — the SwiftUI lifecycle doesn't reliably call `applicationDidFinishLaunching`.
- `NSHostingView` with an explicit frame, **not** `NSHostingController` — the controller collapses to 1×32 px because `GhosttyTerminalView` has zero intrinsic size.
- `SidebarView` must live in its own `NSHostingView` (via `SidebarHostView`), **not** as a sibling of `GhosttyTerminalView` in the same SwiftUI tree. The Metal renderer prevents SwiftUI from invalidating sibling views.
- Prefer POSIX `rename(2)` over `FileManager.moveItem` for atomic replacement — `moveItem` fails silently when the destination exists.
- Any cross-process mutation of `status.json` must `flock(LOCK_EX)` on `.status.lock` first.
- The custom-terminal-background KVO reapply (`AppDelegate+TerminalBackground.swift`) must stay bounded. The `backgroundColor` observer → `reapplyTerminalBackgroundIfDiverged` → `applyTerminalBackground` cycle re-runs a temp-file write + full Ghostty config parse each pass; a non-converging colorspace round-trip once dirtied multi-GB of disk and pegged CPU (build 65). `cgColorsVisuallyEqual` short-circuits the steady state and a per-window circuit breaker (`terminalBackgroundReapplyTripped`, severs the KVO observation past ~12 reapplies / 2 s) is the hard backstop — don't remove either, and keep new code paths off an unbounded reapply→write loop.

## Known dead code

`GhosttyTerminalView.swift` still contains code for splits, notifications, image transfers, tmux layout, drag-and-drop panes, and other features the vendored engine supports but this app doesn't use. They're neutralised by stub types in `Types.swift` but not removed. A future cleanup pass could strip ~3–4K lines and the corresponding stubs.
