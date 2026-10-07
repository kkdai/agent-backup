#!/usr/bin/env bash
# Builds "Agent Backup.app" from the SwiftPM target into build/.
#   scripts/build-app.sh            # release build
#   scripts/build-app.sh --open     # …and launch it
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Agent Backup.app"
VERSION="$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo 0.0.0)"

cd "$ROOT"
swift build -c release --product AgentBackupApp
swift build -c release --product agent-backup
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/AgentBackupApp" "$APP/Contents/MacOS/AgentBackupApp"
# The CLI ships inside the app: scheduled backups (LaunchAgent) run it from here.
cp "$BIN_DIR/agent-backup" "$APP/Contents/MacOS/agent-backup"

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
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleDevelopmentRegion</key><string>zh_TW</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough to run locally. Developer ID signing + notarization is #21.
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

if [[ "${1:-}" == "--open" ]]; then open "$APP"; fi
