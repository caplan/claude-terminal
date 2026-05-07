#!/usr/bin/env bash
# Download the pinned GhosttyKit.xcframework release and link it into the project.
#
# Source of truth: scripts/ghostty.version (ghostty commit SHA) and
# scripts/ghosttykit-checksums.txt (SHA-256 of the tarball).
#
# Prebuilt tarballs are published by the upstream ghostty fork as GitHub release
# assets tagged `xcframework-<ghostty_sha>`. We download, verify the checksum,
# extract to a per-SHA cache dir, and symlink GhosttyKit.xcframework into place.
# No zig required.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VERSION_FILE="$SCRIPT_DIR/ghostty.version"
CHECKSUMS_FILE="$SCRIPT_DIR/ghosttykit-checksums.txt"

cd "$PROJECT_DIR"

# Skip if the symlink already resolves to a valid framework.
if [[ -L "$PROJECT_DIR/GhosttyKit.xcframework" && -d "$PROJECT_DIR/GhosttyKit.xcframework" ]]; then
  echo "==> GhosttyKit.xcframework symlink is valid, skipping."
  exit 0
fi

[[ -f "$VERSION_FILE" ]] || { echo "error: missing $VERSION_FILE" >&2; exit 1; }
[[ -f "$CHECKSUMS_FILE" ]] || { echo "error: missing $CHECKSUMS_FILE" >&2; exit 1; }

GHOSTTY_SHA="$(tr -d '[:space:]' < "$VERSION_FILE")"

EXPECTED_SHA256="$(awk -v sha="$GHOSTTY_SHA" '$1 == sha { print $2; found=1; exit } END { if (!found) exit 1 }' "$CHECKSUMS_FILE" || true)"
if [[ -z "$EXPECTED_SHA256" ]]; then
  echo "error: no checksum pinned for ghostty SHA $GHOSTTY_SHA in $CHECKSUMS_FILE" >&2
  exit 1
fi

CACHE_ROOT="${CLAUDE_TERMINAL_GHOSTTYKIT_CACHE_DIR:-$HOME/.cache/claude-terminal/ghosttykit}"
CACHE_DIR="$CACHE_ROOT/$GHOSTTY_SHA"
CACHE_XCFRAMEWORK="$CACHE_DIR/GhosttyKit.xcframework"

mkdir -p "$CACHE_DIR"

if [[ ! -d "$CACHE_XCFRAMEWORK" ]]; then
  TAG="xcframework-$GHOSTTY_SHA"
  ARCHIVE_NAME="GhosttyKit.xcframework.tar.gz"
  URL="https://github.com/manaflow-ai/ghostty/releases/download/$TAG/$ARCHIVE_NAME"

  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT
  ARCHIVE_PATH="$TMP_DIR/$ARCHIVE_NAME"

  echo "==> Downloading $ARCHIVE_NAME (ghostty $GHOSTTY_SHA)"
  curl --fail --show-error --location \
       --connect-timeout 10 --max-time 300 \
       --retry 5 --retry-delay 10 --retry-all-errors \
       -o "$ARCHIVE_PATH" "$URL"

  ACTUAL_SHA256="$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')"
  if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
    echo "error: checksum mismatch for $ARCHIVE_NAME" >&2
    echo "  expected: $EXPECTED_SHA256" >&2
    echo "  actual:   $ACTUAL_SHA256" >&2
    exit 1
  fi

  tar --no-same-owner -xzf "$ARCHIVE_PATH" -C "$CACHE_DIR"

  if [[ ! -d "$CACHE_XCFRAMEWORK" ]]; then
    echo "error: archive did not contain GhosttyKit.xcframework at expected path" >&2
    exit 1
  fi

  # Xcode 26 can fail to resolve symbols from Ghostty's universal static archive
  # until its ranlib index is refreshed after copy. Re-run ranlib.
  ARCHIVE_LIB="$CACHE_XCFRAMEWORK/macos-arm64_x86_64/libghostty.a"
  if [[ -f "$ARCHIVE_LIB" ]] && command -v xcrun >/dev/null 2>&1; then
    echo "==> Refreshing libghostty archive index"
    xcrun ranlib "$ARCHIVE_LIB" >/dev/null
  fi
fi

echo "==> Linking GhosttyKit.xcframework"
ln -sfn "$CACHE_XCFRAMEWORK" GhosttyKit.xcframework
