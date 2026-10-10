#!/usr/bin/env bash
# Builds "Agent Backup.app" from the SwiftPM target into build/.
#   scripts/build-app.sh            # release build
#   scripts/build-app.sh --open     # …and launch it
#
# Env: VERSION (e.g. 0.3.0) for CFBundleShortVersionString;
#      SIGN_IDENTITY ("Developer ID Application: …") to sign with hardened runtime,
#      otherwise the app is signed ad-hoc (runs locally, not notarizable).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Agent Backup.app"
BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
VERSION="${VERSION:-0.2.0}"

cd "$ROOT"
swift build -c release --product AgentBackupApp
swift build -c release --product agent-backup
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/AgentBackupApp" "$APP/Contents/MacOS/AgentBackupApp"
# The CLI ships inside the app: scheduled backups (LaunchAgent) run it from here.
cp "$BIN_DIR/agent-backup" "$APP/Contents/MacOS/agent-backup"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Agent Backup</string>
  <key>CFBundleDisplayName</key><string>Agent Backup</string>
  <key>CFBundleIdentifier</key><string>com.kkdai.agent-backup</string>
  <key>CFBundleExecutable</key><string>AgentBackupApp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHumanReadableCopyright</key><string>© kkdai · MIT</string>
  <key>CFBundleDevelopmentRegion</key><string>zh_TW</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  # Inner executables first, then the bundle; hardened runtime + secure timestamp are required for notarization.
  for exe in "$APP/Contents/MacOS/agent-backup" "$APP/Contents/MacOS/AgentBackupApp"; do
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$exe"
  done
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
  codesign --verify --deep --strict "$APP"
  echo "Signed with $SIGN_IDENTITY"
else
  codesign --force --deep --sign - "$APP" >/dev/null
fi
echo "Built $APP ($VERSION, build $BUILD)"

if [[ "${1:-}" == "--open" ]]; then open "$APP"; fi
