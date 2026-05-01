# claude-terminal

A native macOS app for running [Claude Code](https://docs.claude.com/en/docs/claude-code/overview) sessions, with a live sidebar, inline markdown preview, and multi-window session management.

Built on [Ghostty](https://ghostty.org)'s terminal engine.

## Install

1. Download `claude-terminal-X.Y.Z.dmg` from the [latest release](../../releases/latest).
2. Open the DMG and drag **claude-terminal** to `/Applications`.
3. Launch it. Updates arrive automatically via Sparkle.

Requires macOS 14 and the [Claude Code CLI](https://docs.claude.com/en/docs/claude-code/setup):

```bash
npm install -g @anthropic-ai/claude-code
```

## Using it

On first launch you'll see a directory picker. Pick the project folder you want to work in and claude-terminal starts a Claude Code session there. Every new window = a separate Claude session.

### Command line

On first launch the app offers to install a symlink at `~/.local/bin/claude-terminal`. Once installed:

```bash
claude-terminal                              # directory picker
claude-terminal ~/projects/myapp             # specific directory
claude-terminal --name "feature work" .      # named session
claude-terminal ~/myapp -- --resume          # pass args through to claude
```

If the app is already running, the CLI opens a new window in the same process.

## What you get

### Live sidebar

- Status, current tool, and active subagents — color-tinted by state (thinking, tool use, streaming).
- Context window usage, cost, API latency, and running token counts.
- Task list with dependency ordering and blocked-task indicators.
- Jira ticket detection from your branch name, with clickable link.
- Project favicons auto-loaded from the working directory.
- Auto-collapses to single-line summaries when the window is short; cost and context always stay visible.

### Inline markdown viewer

- Any `.md` file Claude reads, writes, or edits shows up in the sidebar as a preview card (filename + first heading + excerpt).
- Click a card — or drag any `.md` onto the sidebar — to open it in a tab that covers the terminal area, leaving the sidebar in place.
- Full GitHub-flavored markdown: tables, task lists, fenced code with syntax highlighting, and **mermaid diagrams** rendered inline.
- Each mermaid diagram supports ⌘-scroll zoom, drag-pan, and double-click reset.
- `Cmd+F` searches the open document; `Cmd+=` / `Cmd+-` / `Cmd+0` zoom.
- Files auto-reload when Claude edits them; scroll position survives tab switching and quitting the app.
- Open `.md` files from Finder with **Open With → claude-terminal**.

### Window + session management

- Multi-window: run several Claude sessions side by side, switch via the Window menu (`Cmd+1`-`Cmd+9`) or the menu-bar icon.
- Menu-bar icon pops up a grid of all sessions (active + recently used) — click to focus or reopen. Toggle the trigger (hover vs click) and visibility in Settings → Menu Bar.
- Window size, position, sidebar width, and renamed session names persist across restarts.
- **Save & Quit** reopens every window with `--continue` on next launch, including open doc tabs and scroll positions.
- Subagents can be force-quit from the sidebar with right-click.

### Integrations

- Native macOS notifications when Claude needs your attention (toggle in Settings).
- Jira CLI integration for ticket titles (supports both `ankitpokhrel/jira-cli` and `go-jira`).

## Keyboard shortcuts

| Action | Shortcut |
|---|---|
| New session | `Cmd+N` |
| Open session | `Cmd+O` |
| Close window | `Cmd+W` |
| Toggle sidebar | `Cmd+B` |
| Rename session | `Cmd+Shift+R` |
| Switch to window 1-9 | `Cmd+1` … `Cmd+9` |
| Find in open markdown doc | `Cmd+F` |
| Find next / previous | `Cmd+G` / `Cmd+Shift+G` |
| Zoom markdown in / out / reset | `Cmd+=` / `Cmd+-` / `Cmd+0` |

## Uninstall

`claude-terminal` menu → **Uninstall Claude Terminal…** removes the app from `/Applications`, deletes `~/.claude-terminal/`, strips the claude-terminal hook + statusLine entries from `~/.claude/settings.json`, removes the CLI symlink, and clears app preferences.

## Contributing

Source layout, build instructions, release process, and architecture notes live under [docs/](./docs/) and [CONTRIBUTING.md](./CONTRIBUTING.md).

## License

[MIT](./LICENSE)
