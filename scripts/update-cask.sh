#!/usr/bin/env bash
# Writes a filled-in cask: scripts/update-cask.sh <version> [sha256] > agent-backup.rb
# Without sha256, it is read from the release's .sha256 asset.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$1"
SHA="${2:-$(gh release download "v$VERSION" -R kkdai/agent-backup -p "*.sha256" -O - | awk '{print $1}')}"
sed -e "s/__VERSION__/$VERSION/" -e "s/__SHA256__/$SHA/" "$ROOT/packaging/homebrew/agent-backup.rb.template"
