# claude-terminal

Multi-window macOS AppKit app that wraps Ghostty's terminal engine for running Claude Code sessions, with a live SwiftUI sidebar and an inline GFM + mermaid markdown viewer.

Bundle ID: `org.claire.claude-terminal`.

## Where to find things

- User-facing docs: [README.md](README.md).
- Contributor guide (local build, release flow, one-time setup): [CONTRIBUTING.md](CONTRIBUTING.md).
- **Architecture reference — read this before making structural changes:** [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). It covers the portal system, session-monitor IPC, cost accounting, document persistence, and the vendored-code boundary.

## Hard rules (also in docs/ARCHITECTURE.md § Conventions, but important enough to repeat)

- **Don't modify `Sources/GhosttyTerminalView.swift`** — ~12.6K lines of vendored terminal-engine code. If a change seems necessary, add stubs to `Sources/Types.swift` or host methods to `Sources/AppDelegate.swift` instead.
- When adding stubs, match the exact signatures `GhosttyTerminalView.swift` expects (argument labels, return types, default values).
- AppKit lifecycle is hand-rolled in `Sources/main.swift`. Don't switch to SwiftUI `@main` — the SwiftUI lifecycle doesn't reliably call `applicationDidFinishLaunching`.
- Use `NSHostingView` with an explicit frame, not `NSHostingController` — the controller collapses to 1×32 px because `GhosttyTerminalView` has zero intrinsic size.
- `SidebarView` must live in its own `NSHostingView` (via `SidebarHostView`). The Metal renderer prevents SwiftUI from invalidating sibling views.
- Never re-introduce cost summation on our side; `Claude Code`'s `total_cost_usd` is already cumulative across `--continue`. See `Sources/Hook/main.swift:runStatusLine`.
- Atomic file replacement uses POSIX `rename(2)`, not `FileManager.moveItem` (which silently drops overwrites under `try?`). Any cross-process mutation of `status.json` must hold `flock(LOCK_EX)` on `.status.lock` first.
- Stay on `0.x` releases. Do not create `1.x` tags.

## Build quickly

```bash
./scripts/ensure-ghosttykit.sh && xcodegen generate && \
  xcodebuild -project claude-terminal.xcodeproj -scheme claude-terminal -configuration Debug build
```

Release flow: `scripts/release.sh <version>` (full details in CONTRIBUTING.md).
