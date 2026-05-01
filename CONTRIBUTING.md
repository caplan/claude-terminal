# Contributing

claude-terminal is a native macOS AppKit app wrapping Ghostty's terminal engine. It's maintained as a personal project, but PRs and bug reports are welcome.

If you're just poking around the codebase, the architecture overview is at [docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md).

## Local development

Prereqs:

- Xcode 15+ (macOS 14 SDK).
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.

No zig or ghostty source checkout needed — the build script downloads a prebuilt `GhosttyKit.xcframework` release asset keyed by a pinned commit SHA.

```bash
git clone https://github.com/caplan/claude-terminal.git
cd claude-terminal

# Download GhosttyKit.xcframework (~132MB, cached in ~/.cache/claude-terminal/)
./scripts/ensure-ghosttykit.sh

# Generate claude-terminal.xcodeproj from project.yml
xcodegen generate

# Build
xcodebuild -project claude-terminal.xcodeproj -scheme claude-terminal -configuration Debug build

# Run (launches the Debug build alongside any installed release)
open -n ~/Library/Developer/Xcode/DerivedData/claude-terminal-*/Build/Products/Debug/claude-terminal.app
```

Regenerate the Xcode project after editing `project.yml`:

```bash
xcodegen generate
```

## Bumping GhosttyKit

`scripts/ensure-ghosttykit.sh` pulls `GhosttyKit.xcframework.tar.gz` from the [manaflow-ai/ghostty](https://github.com/manaflow-ai/ghostty) release pipeline at tag `xcframework-<sha>`, verifies the SHA-256 against `scripts/ghosttykit-checksums.txt`, extracts to `~/.cache/claude-terminal/ghosttykit/<sha>/`, and symlinks the framework into the project root.

To bump:

1. Update the SHA in `scripts/ghostty.version`.
2. Add a matching line to `scripts/ghosttykit-checksums.txt`.
3. Re-run `./scripts/ensure-ghosttykit.sh`.

## Cutting a release

Releases ship as Developer-ID-signed, notarized `.dmg` bundles attached to GitHub Releases. The app auto-updates via [Sparkle](https://sparkle-project.org/) against `appcast.xml` hosted in the repo.

### One-time setup

1. **Apple Developer cert.** Xcode → Settings → Accounts → sign in → *Manage Certificates… → + → Developer ID Application.* Grab the 10-char Team ID from [developer.apple.com/account](https://developer.apple.com/account) → Membership.

2. **Shell env.** Add to `~/.zshrc`:
   ```bash
   export DEVELOPMENT_TEAM=XXXXXXXXXX
   ```

3. **Notarytool keychain profile.** Create an app-specific password at [appleid.apple.com](https://appleid.apple.com), then run once:
   ```bash
   xcrun notarytool store-credentials "claude-terminal-notarytool" \
     --apple-id your-apple-id@example.com \
     --team-id "$DEVELOPMENT_TEAM" \
     --password <app-specific-password>
   ```

4. **Sparkle EdDSA keys.** After the first Release build resolves Sparkle via SPM, its tools land at `~/Library/Developer/Xcode/DerivedData/claude-terminal-*/SourcePackages/artifacts/sparkle/Sparkle/bin/`. Run `generate_keys` once — it stores the private key in the login keychain and prints the public key. Paste the public key into `Resources/Info.plist` under `SUPublicEDKey`.

5. **GitHub CLI.** `brew install gh && gh auth login`.

### Release flow

```bash
scripts/release.sh 0.35.2
```

The script:

1. Bumps `MARKETING_VERSION` in `project.yml` and regenerates the Xcode project.
2. Archives, exports with Developer ID.
3. Zips the `.app` and submits to `notarytool`, then staples the ticket.
4. Builds a `.dmg` via `hdiutil`, signs + notarizes + staples it.
5. Signs the DMG for Sparkle and appends an `<item>` to `appcast.xml`.
6. Commits + tags + pushes.
7. Creates the GitHub Release with the DMG attached via `gh release create`.

Users running older versions get an update prompt within 24h (or on next *Check for Updates…*).

### Versioning

Stay on `0.x` releases. Do not create `1.x` tags or releases yet.

## Project conventions

See [docs/ARCHITECTURE.md § Conventions](./docs/ARCHITECTURE.md#conventions) for the rules that keep the Metal-rendered terminal, the vendored Ghostty code, and the SwiftUI sidebar playing nicely together.

## Repo layout

```
README.md                 — user-facing docs
CONTRIBUTING.md           — this file
LICENSE                   — MIT
CLAUDE.md                 — instructions for Claude Code when working in this repo
docs/
  ARCHITECTURE.md         — architecture deep dive
Sources/                  — Swift sources (AppKit app + hook binary)
  Hook/                   — claude-terminal-hook helper binary
Resources/
  Info.plist
  Assets.xcassets         — app icon
  ghostty/                — Ghostty runtime resources
  markdown-viewer/        — bundled JS/CSS for the inline markdown tab
scripts/
  release.sh              — notarize + sign + ship
  ensure-ghosttykit.sh    — download pinned GhosttyKit.xcframework
  uninstall.sh            — user-invokable uninstaller
project.yml               — XcodeGen project config
appcast.xml               — Sparkle feed
```
