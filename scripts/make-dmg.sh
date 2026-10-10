#!/usr/bin/env bash
# Packs build/Agent Backup.app into build/AgentBackup-<version>.dmg (app + Applications link).
#   VERSION=0.3.0 scripts/make-dmg.sh
# Env: SIGN_IDENTITY signs the DMG; NOTARY_PROFILE (a `notarytool store-credentials` profile)
#      or APPLE_ID + APPLE_TEAM_ID + APPLE_APP_PASSWORD notarize and staple it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-0.2.0}"
APP="$ROOT/build/Agent Backup.app"
DMG="$ROOT/build/AgentBackup-$VERSION.dmg"
[[ -d "$APP" ]] || { echo "Run scripts/build-app.sh first"; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Agent Backup" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi

notarize=()
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  notarize=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]]; then
  notarize=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD")
fi
if [[ ${#notarize[@]} -gt 0 ]]; then
  xcrun notarytool submit "$DMG" "${notarize[@]}" --wait
  xcrun stapler staple "$DMG"
  echo "Notarized and stapled"
fi

shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "Built $DMG"
