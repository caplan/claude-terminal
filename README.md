# claude-terminal

A native macOS app for running Claude Code sessions with a live sidebar showing real-time session state.

Built on [Ghostty](https://ghostty.org)'s terminal engine with a purpose-built UI for Claude Code workflows.

## Features

- **Live sidebar** — status, current tool with verb/detail, subagent tool details, context, cost, tasks
- **API latency** — live metrics: last response time, average per turn, API time percentage
- **Documents** — persistent clickable links to .md files Claude writes, with right-click context menu (Open With, Show in Finder, Copy Path). Excludes memory files.
- **Clickable file paths** — tool detail paths open in default app when clicked
- **Task dependencies** — tasks sorted by dependency order with indentation and blocked indicators
- **Parallel tool calls** — all concurrent tools shown simultaneously in the status card
- **Adaptive layout** — API latency, cost, and context cards auto-collapse when window is short
- **Resizable sidebar** — drag the edge to resize (220-500pt), width persists across sessions
- **Jira integration** — detects ticket from branch name, shows clickable link with wrapping title
- **Project favicons** — auto-detected from working directory, shown in sidebar and Window menu
- **Multi-window** — run multiple Claude sessions side by side, switch via Window menu (Cmd+1-9)
- **Menubar icon** — hover (or click) the menubar icon for a grid of all sessions, current and recent. Each tile shows session name, directory, status, and cost, with background color derived from the project's favicon. Click a tile to focus (if open) or reopen (if past). Toggle in Settings > Menu Bar.
- **Save & restore** — save open windows on quit, reopen with `--continue` on next launch
- **Notifications** — native macOS notifications when Claude needs input. Toggle in Settings.
- **Session persistence** — window size/position and renamed session names persist across restarts
- **Subagent management** — right-click to Force Quit agents from sidebar
- **Rename sessions** — via pencil icon in sidebar or View > Rename Session (Cmd+Shift+R)
- **Uninstall** — clean removal via menu item or `scripts/uninstall.sh`

## Install

### From release

Download `claude-terminal.dmg` from [Releases](../../releases), open it, drag the app to `~/Applications`, then:

```bash
xattr -cr ~/Applications/claude-terminal.app
```

### From source

Requires Xcode and [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). No zig or ghostty checkout needed — the build script downloads a prebuilt `GhosttyKit.xcframework` release asset and verifies its SHA-256.

```bash
git clone https://github.com/caplan/claude-terminal.git
cd claude-terminal

# Download GhosttyKit.xcframework (~132MB, cached in ~/.cache/claude-terminal/)
./scripts/ensure-ghosttykit.sh

# Generate xcodeproj
xcodegen generate

# Build
xcodebuild -project claude-terminal.xcodeproj -scheme claude-terminal -configuration Release build

# Install
cp -R ~/Library/Developer/Xcode/DerivedData/claude-terminal-*/Build/Products/Release/claude-terminal.app /Applications/ && codesign --force --deep --sign - /Applications/claude-terminal.app
```

## CLI Usage

```bash
# Open with directory picker
claude-terminal

# Open specific directory
claude-terminal ~/myproject

# Named session
claude-terminal --name "feature-work" ~/myproject

# Pass arguments through to Claude CLI
claude-terminal ~/myproject -- --resume --dangerously-skip-permissions
```

If the app is already running, the CLI opens a new window in the existing instance.

On first launch, the app offers to install a symlink at `~/.local/bin/claude-terminal`.

## How it works

Each window launches Claude Code in a Ghostty terminal with a unique session ID. Two scripts feed live data into a JSON file that the sidebar watches:

1. **Hook script** — fires on tool use, agent start/stop, task events, prompt submit
2. **Status line script** — polled every 3s for context window, cost, and model info

The sidebar updates in real time as Claude works.

## Keyboard shortcuts

| Action | Shortcut |
|--------|----------|
| New Session | Cmd+N |
| Open Session | Cmd+O |
| Close Window | Cmd+W |
| Toggle Sidebar | Cmd+B |
| Rename Session | Cmd+Shift+R |
| Switch Window 1-9 | Cmd+1 through Cmd+9 |
| Resize Sidebar | Drag left edge |

## Requirements

- macOS 14.0+
- Claude Code CLI (`npm install -g @anthropic-ai/claude-code`)

## Releasing

Releases ship as Developer ID-signed, notarized `.app` bundles attached to GitHub Releases. The app auto-updates via [Sparkle](https://sparkle-project.org/) against an `appcast.xml` hosted in this repo.

### One-time setup

1. **Apple Developer cert.** In Xcode → Settings → Accounts, sign in with your Apple ID and use "Manage Certificates…" → `+` → "Developer ID Application". Grab the 10-char Team ID from [developer.apple.com/account](https://developer.apple.com/account) → Membership.

2. **Shell env.** Add to `~/.zshrc`:

   ```bash
   export DEVELOPMENT_TEAM=XXXXXXXXXX
   ```

3. **Notarytool keychain profile.** Create an app-specific password at [appleid.apple.com](https://appleid.apple.com), then store credentials once:

   ```bash
   xcrun notarytool store-credentials "claude-terminal-notarytool" \
     --apple-id your-apple-id@example.com \
     --team-id "$DEVELOPMENT_TEAM" \
     --password <app-specific-password>
   ```

4. **Sparkle EdDSA keys.** After the first Release build resolves Sparkle via SPM, its tools land at `~/Library/Developer/Xcode/DerivedData/claude-terminal-*/SourcePackages/artifacts/sparkle/Sparkle/bin/`. Run `generate_keys` once — it stores the private key in the login keychain and prints the public key. Paste the public key into `Resources/Info.plist` under `SUPublicEDKey`.

5. **GitHub CLI.** `brew install gh && gh auth login`.

### Cut a release

```bash
scripts/release.sh 0.30.0
```

This bumps the version in `project.yml`, archives, exports with Developer ID, notarizes, staples, re-zips, signs the update with Sparkle, appends an `<item>` to `appcast.xml`, commits + tags, and creates the GitHub Release with the zipped `.app` attached.

Users running older versions get an update prompt within 24h (or on next `Check for Updates…`).
