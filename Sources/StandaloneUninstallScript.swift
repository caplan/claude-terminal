import Foundation

/// Content of the standalone uninstaller we drop at
/// `~/.claude-terminal/uninstall.sh` on every app launch. This script is the
/// drag-to-Trash safety net: if the user removes the app bundle without
/// going through the in-app Uninstall menu, they can still run this script
/// from a terminal to clean up Claude Code hooks, preferences, and the CLI
/// symlink.
///
/// Keep this in sync with `scripts/uninstall.sh` — they're intentionally
/// similar so a user who has the repo sees the same behavior as one who
/// only has the installed app.
enum StandaloneUninstallScript {
    static let content: String = #"""
#!/usr/bin/env bash
# claude-terminal uninstaller — dropped here by the app on every launch so
# it survives drag-to-Trash. Safe to run even after the app bundle is gone.
set -euo pipefail

echo "Claude Terminal Uninstaller"
echo "==========================="
echo ""
echo "This will remove:"
for candidate in "$HOME/Applications/claude-terminal.app" "/Applications/claude-terminal.app"; do
    if [[ -d "$candidate" ]]; then
        echo "  • $candidate"
    fi
done
echo "  • ~/.claude-terminal/ (session data + this script)"
echo "  • ~/.local/bin/claude-terminal (CLI symlink, if present)"
echo "  • Claude Code hook + statusLine entries referencing claude-terminal"
echo "  • App preferences (org.claire.claude-terminal)"
echo ""
read -p "Proceed? [y/N] " -n 1 -r
echo ""
[[ $REPLY =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }
echo ""

for candidate in "$HOME/Applications/claude-terminal.app" "/Applications/claude-terminal.app"; do
    if [[ -d "$candidate" ]]; then
        echo "Removing $candidate..."
        rm -rf "$candidate" 2>/dev/null || sudo rm -rf "$candidate"
    fi
done

if [[ -L "$HOME/.local/bin/claude-terminal" ]] || [[ -f "$HOME/.local/bin/claude-terminal" ]]; then
    echo "Removing ~/.local/bin/claude-terminal..."
    rm -f "$HOME/.local/bin/claude-terminal"
fi

CLAUDE_SETTINGS="$HOME/.claude/settings.json"
if [[ -f "$CLAUDE_SETTINGS" ]]; then
    echo "Cleaning Claude Code settings..."
    python3 - "$CLAUDE_SETTINGS" <<'PY'
import json, sys

path = sys.argv[1]
with open(path) as f:
    settings = json.load(f)

changed = False

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
elif changed:
    settings["hooks"] = hooks

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

echo "Removing app preferences..."
defaults delete org.claire.claude-terminal 2>/dev/null || true

# Remove session data last — this script lives inside ~/.claude-terminal,
# so we'd pull the rug out from under ourselves if we did it earlier.
if [[ -d "$HOME/.claude-terminal" ]]; then
    echo "Removing ~/.claude-terminal/..."
    rm -rf "$HOME/.claude-terminal"
fi

echo ""
echo "Done. Claude Terminal has been uninstalled."
"""#
}
