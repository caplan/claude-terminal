#!/usr/bin/env bash
# Build, notarize, and release a new claude-terminal version.
#
# Prereqs (one-time):
#   - Apple ID caplan@claire.org signed in to Xcode, Developer ID Application cert installed
#   - export DEVELOPMENT_TEAM=XXXXXXXXXX (10-char Team ID) in ~/.zshrc
#   - xcrun notarytool store-credentials "claude-terminal-notarytool" \
#         --apple-id caplan@claire.org --team-id "$DEVELOPMENT_TEAM" --password <app-specific>
#   - Sparkle's generate_keys run once (private key stored in login keychain)
#   - SUPublicEDKey filled in Resources/Info.plist
#   - gh auth login
#
# Usage:
#   scripts/release.sh 0.30.0

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <version>" >&2
  echo "example: $0 0.30.0" >&2
  exit 1
fi

NEW_VERSION="$1"
if [[ ! "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version must look like 0.30.0" >&2
  exit 1
fi

: "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM to your 10-char Apple Team ID}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/claude-terminal.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP_PATH="$EXPORT_DIR/claude-terminal.app"
NOTARIZE_ZIP_PATH="$BUILD_DIR/claude-terminal-$NEW_VERSION-notarize.zip"
DMG_NAME="claude-terminal-$NEW_VERSION.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"
DMG_STAGING="$BUILD_DIR/dmg-staging"
APPCAST_PATH="$PROJECT_DIR/appcast.xml"
NOTARY_PROFILE="claude-terminal-notarytool"
RELEASE_URL="https://github.com/caplan/claude-terminal/releases/download/v$NEW_VERSION/$DMG_NAME"

cd "$PROJECT_DIR"

# 1. Verify clean working tree
if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: working tree is not clean" >&2
  git status --short >&2
  exit 1
fi

# 2. Locate tooling
command -v xcodegen >/dev/null || { echo "error: xcodegen not found (brew install xcodegen)" >&2; exit 1; }
command -v gh >/dev/null || { echo "error: gh not found (brew install gh)" >&2; exit 1; }
command -v /usr/libexec/PlistBuddy >/dev/null || { echo "error: PlistBuddy missing" >&2; exit 1; }

# Verify SUPublicEDKey is set (Sparkle refuses to verify updates otherwise)
PUBKEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PROJECT_DIR/Resources/Info.plist" 2>/dev/null || true)"
if [[ -z "$PUBKEY" ]]; then
  echo "error: SUPublicEDKey is empty in Resources/Info.plist" >&2
  echo "run Sparkle's generate_keys and paste the public key into Info.plist first" >&2
  exit 1
fi

# 3. Bump version in project.yml
CURRENT_VERSION="$(awk '/MARKETING_VERSION:/ { gsub(/"/, "", $2); print $2; exit }' project.yml)"
CURRENT_BUILD="$(awk '/CURRENT_PROJECT_VERSION:/ { gsub(/"/, "", $2); print $2; exit }' project.yml)"
NEW_BUILD="$((CURRENT_BUILD + 1))"
echo "==> Bumping $CURRENT_VERSION ($CURRENT_BUILD) → $NEW_VERSION ($NEW_BUILD)"
/usr/bin/sed -i '' -E "s/MARKETING_VERSION: \"$CURRENT_VERSION\"/MARKETING_VERSION: \"$NEW_VERSION\"/" project.yml
/usr/bin/sed -i '' -E "s/CURRENT_PROJECT_VERSION: \"$CURRENT_BUILD\"/CURRENT_PROJECT_VERSION: \"$NEW_BUILD\"/" project.yml
xcodegen generate

# 4. Clean build dir + archive
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
echo "==> Archiving"
xcodebuild \
  -project claude-terminal.xcodeproj \
  -scheme claude-terminal \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  CODE_SIGN_STYLE=Manual \
  archive

# 5. Export signed .app with Developer ID
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
/usr/bin/sed "s/__DEVELOPMENT_TEAM__/$DEVELOPMENT_TEAM/" "$SCRIPT_DIR/ExportOptions.plist.template" > "$EXPORT_OPTIONS"
echo "==> Exporting"
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS"

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: export did not produce $APP_PATH" >&2
  exit 1
fi

# 6. Zip the .app for notarization (notarytool needs a container; DMG will be made after)
echo "==> Zipping .app for notarization"
/usr/bin/ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP_PATH"

# 7. Notarize + staple the .app
echo "==> Submitting .app to notarytool (waits for ticket)"
xcrun notarytool submit "$NOTARIZE_ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
echo "==> Stapling .app"
xcrun stapler staple "$APP_PATH"
rm -f "$NOTARIZE_ZIP_PATH"

# 8. Build a DMG containing the stapled .app + /Applications symlink
echo "==> Building DMG"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
/usr/bin/ditto "$APP_PATH" "$DMG_STAGING/$(basename "$APP_PATH")"
ln -s /Applications "$DMG_STAGING/Applications"
rm -f "$DMG_PATH"
hdiutil create \
  -volname "claude-terminal $NEW_VERSION" \
  -srcfolder "$DMG_STAGING" \
  -ov \
  -format UDZO \
  -fs HFS+ \
  "$DMG_PATH"

# 9. Sign the DMG with Developer ID so Gatekeeper trusts the container itself
echo "==> Signing DMG"
codesign --force --sign "Developer ID Application" --timestamp "$DMG_PATH"

# 10. Notarize + staple the DMG
echo "==> Submitting DMG to notarytool (waits for ticket)"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
echo "==> Stapling DMG"
xcrun stapler staple "$DMG_PATH"

# 11. Sign update for Sparkle — requires Sparkle's sign_update to be on PATH
SIGN_UPDATE="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update' 2>/dev/null | head -n1)"
if [[ -z "$SIGN_UPDATE" ]]; then
  echo "error: sign_update not found; build Release once so SPM resolves Sparkle first" >&2
  exit 1
fi
echo "==> Signing update for Sparkle"
SIGN_OUTPUT="$("$SIGN_UPDATE" "$DMG_PATH")"
# sign_update prints: sparkle:edSignature="..." length="N"
ED_SIG="$(echo "$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
LENGTH="$(echo "$SIGN_OUTPUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"
if [[ -z "$ED_SIG" || -z "$LENGTH" ]]; then
  echo "error: could not parse sign_update output: $SIGN_OUTPUT" >&2
  exit 1
fi

# 12. Append <item> to appcast.xml (insert before </channel>)
PUB_DATE="$(LC_TIME=en_US.UTF-8 date -u '+%a, %d %b %Y %H:%M:%S +0000')"
NEW_ITEM=$(cat <<EOF
    <item>
      <title>Version $NEW_VERSION</title>
      <link>https://github.com/caplan/claude-terminal/releases/tag/v$NEW_VERSION</link>
      <sparkle:version>$NEW_BUILD</sparkle:version>
      <sparkle:shortVersionString>$NEW_VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <pubDate>$PUB_DATE</pubDate>
      <enclosure
        url="$RELEASE_URL"
        sparkle:edSignature="$ED_SIG"
        length="$LENGTH"
        type="application/x-apple-diskimage" />
    </item>
EOF
)
# Write a temp file with the new item, then awk it in before </channel>
TMP_ITEM="$(mktemp)"
printf '%s\n' "$NEW_ITEM" > "$TMP_ITEM"
awk -v itemfile="$TMP_ITEM" '
  /<\/channel>/ {
    while ((getline line < itemfile) > 0) print line
    close(itemfile)
  }
  { print }
' "$APPCAST_PATH" > "$APPCAST_PATH.new"
mv "$APPCAST_PATH.new" "$APPCAST_PATH"
rm -f "$TMP_ITEM"

# 13. Commit + tag + release
echo "==> Committing + tagging"
git add project.yml appcast.xml
git commit -m "Release v$NEW_VERSION"
git tag "v$NEW_VERSION"
git push origin HEAD
git push origin "v$NEW_VERSION"

echo "==> Creating GitHub release"
gh release create "v$NEW_VERSION" \
  "$DMG_PATH" \
  --title "v$NEW_VERSION" \
  --generate-notes

echo "==> Done: v$NEW_VERSION"
echo "    Appcast URL: https://raw.githubusercontent.com/caplan/claude-terminal/main/appcast.xml"
echo "    Release: https://github.com/caplan/claude-terminal/releases/tag/v$NEW_VERSION"
