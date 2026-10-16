#!/bin/zsh
set -euo pipefail

# Find the app by looking at where this script lives, or common locations
SCRIPT_DIR="${0:A:h}"
APP_PATH=""

# If script is inside the .app bundle
if [[ "$SCRIPT_DIR" == *"claude-terminal.app"* ]]; then
    APP_PATH="${SCRIPT_DIR%%claude-terminal.app/*}claude-terminal.app"
# If script is in the repo scripts/ dir, look for installed app
elif [[ -d "$SCRIPT_DIR/../claude-terminal.app" ]]; then
    APP_PATH="${SCRIPT_DIR:h}/claude-terminal.app"
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

CLAUDE_SETTINGS="$HOME/.claude/settings.json"

echo "Claude Terminal Uninstaller"
echo "==========================="
echo ""
echo "This will remove:"
if [[ -n "$APP_PATH" ]]; then
    echo "  • $APP_PATH"
else
    echo "  • claude-terminal.app (not found)"
fi
echo "  • ~/.claude-terminal/ (session data)"
echo "  • ~/.local/bin/claude-terminal (CLI symlink)"
echo "  • Claude Code hook/statusLine entries an older version left in ~/.claude/settings.json"
echo "  • App preferences (org.claire.claude-terminal)"
echo ""
read -q "REPLY?Proceed? [y/N] " || { echo ""; echo "Cancelled."; exit 0; }
echo ""
echo ""

# Remove the app
if [[ -n "$APP_PATH" && -d "$APP_PATH" ]]; then
    echo "Removing $APP_PATH..."
    rm -rf "$APP_PATH"
fi

# Remove session data
if [[ -d "$HOME/.claude-terminal" ]]; then
    echo "Removing ~/.claude-terminal/..."
    rm -rf "$HOME/.claude-terminal"
fi

# Remove CLI symlink
if [[ -L "$HOME/.local/bin/claude-terminal" ]] || [[ -f "$HOME/.local/bin/claude-terminal" ]]; then
    echo "Removing ~/.local/bin/claude-terminal..."
    rm -f "$HOME/.local/bin/claude-terminal"
fi

# Current versions write nothing to settings.json: the sidebar-bridge mod loads
# per session. Versions before 0.43 added hook and statusLine entries, which the
# app removes at launch. This covers a person who never launched a newer one.
if [[ -f "$CLAUDE_SETTINGS" ]]; then
    JQ_SCRUB='
      def ours: tostring | test("claude-terminal");
      (if .hooks then
        .hooks |= (with_entries(.value |= map(select(ours | not)))
                   | with_entries(select(.value | length > 0)))
        | if .hooks == {} then del(.hooks) else . end
      else . end)
      | if (.statusLine // {} | ours) then del(.statusLine) else . end'
    if ! command -v jq >/dev/null; then
        echo "  jq not found: remove any entry containing 'claude-terminal' from $CLAUDE_SETTINGS by hand."
    elif grep -q "claude-terminal" "$CLAUDE_SETTINGS"; then
        echo "Cleaning Claude Code settings..."
        tmp="$CLAUDE_SETTINGS.claude-terminal.tmp"
        if jq "$JQ_SCRUB" "$CLAUDE_SETTINGS" > "$tmp"; then
            mv -f "$tmp" "$CLAUDE_SETTINGS"
            echo "  Removed claude-terminal entries from settings.json"
        else
            rm -f "$tmp"
            echo "  Could not parse $CLAUDE_SETTINGS: remove any entry containing 'claude-terminal' by hand."
        fi
    fi
fi

# Remove preferences
echo "Removing app preferences..."
defaults delete org.claire.claude-terminal 2>/dev/null || true

echo ""
echo "Done. Claude Terminal has been uninstalled."
