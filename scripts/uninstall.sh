#!/usr/bin/env bash
set -euo pipefail

# Find the app by looking at where this script lives, or common locations
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_PATH=""

# If script is inside the .app bundle
if [[ "$SCRIPT_DIR" == *"claude-terminal.app"* ]]; then
    APP_PATH="${SCRIPT_DIR%%claude-terminal.app/*}claude-terminal.app"
# If script is in the repo scripts/ dir, look for installed app
elif [[ -d "$SCRIPT_DIR/../claude-terminal.app" ]]; then
    APP_PATH="$(cd "$SCRIPT_DIR/.." && pwd)/claude-terminal.app"
else
    # Search common locations
    for candidate in \
        "$HOME/Applications/claude-terminal.app" \
        "/Applications/claude-terminal.app" \
        "$HOME/Desktop/claude-terminal.app"; do
        if [[ -d "$candidate" ]]; then
            APP_PATH="$candidate"
            break
        fi
    done
fi

echo "Claude Terminal Uninstaller"
echo "==========================="
echo ""
echo "This will remove:"
if [[ -n "$APP_PATH" ]]; then
    echo "  • $APP_PATH"
else
    echo "  • claude-terminal.app (not found)"
fi
echo "  • ~/.claude-terminal/ (session data & hooks)"
echo "  • ~/.local/bin/claude-terminal (CLI symlink)"
echo "  • Claude Code hook/statusLine entries from ~/.claude/settings.json"
echo "  • App preferences (org.claire.claude-terminal)"
echo ""
read -p "Proceed? [y/N] " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

echo ""

# Remove the app
if [[ -n "$APP_PATH" && -d "$APP_PATH" ]]; then
    echo "Removing $APP_PATH..."
    rm -rf "$APP_PATH"
fi

# Remove session data and hooks
if [[ -d "$HOME/.claude-terminal" ]]; then
    echo "Removing ~/.claude-terminal/..."
    rm -rf "$HOME/.claude-terminal"
fi

# Remove CLI symlink
if [[ -L "$HOME/.local/bin/claude-terminal" ]] || [[ -f "$HOME/.local/bin/claude-terminal" ]]; then
    echo "Removing ~/.local/bin/claude-terminal..."
    rm -f "$HOME/.local/bin/claude-terminal"
fi

# Clean up ~/.claude/settings.json
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
if [[ -f "$CLAUDE_SETTINGS" ]]; then
    echo "Cleaning Claude Code settings..."
    python3 - "$CLAUDE_SETTINGS" <<'PY'
import json, sys

path = sys.argv[1]
with open(path) as f:
    settings = json.load(f)

changed = False

# Remove hooks that reference claude-terminal
hooks = settings.get("hooks", {})
for event in list(hooks.keys()):
    entries = hooks[event]
    if not isinstance(entries, list):
        continue
    filtered = []
    for entry in entries:
        hook_list = entry.get("hooks", [])
        if isinstance(hook_list, list) and any("claude-terminal" in (h.get("command", "") or "") for h in hook_list):
            changed = True
            continue
        if "claude-terminal" in (entry.get("command", "") or ""):
            changed = True
            continue
        filtered.append(entry)
    if filtered:
        hooks[event] = filtered
    else:
        del hooks[event]
        changed = True

if not hooks and "hooks" in settings:
    del settings["hooks"]
    changed = True
elif changed:
    settings["hooks"] = hooks

# Remove statusLine if it references claude-terminal
sl = settings.get("statusLine", {})
if isinstance(sl, dict) and "claude-terminal" in (sl.get("command", "") or ""):
    del settings["statusLine"]
    changed = True

if changed:
    with open(path, "w") as f:
        json.dump(settings, f, indent=4, sort_keys=True)
    print("  Removed claude-terminal entries from settings.json")
else:
    print("  No claude-terminal entries found in settings.json")
PY
fi

# Remove preferences
echo "Removing app preferences..."
defaults delete org.claire.claude-terminal 2>/dev/null || true

echo ""
echo "Done. Claude Terminal has been uninstalled."
