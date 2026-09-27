#!/bin/zsh
# Builds the app and zips it for a GitHub release:
#   dist/Huawei-360-<version>-macOS-arm64.zip (+ .sha256)
#   dist/appcast.xml — Sparkle auto-update feed, when a signing key is available:
#     CI: SPARKLE_ED_PRIVATE_KEY (repository secret) · local: APPCAST=1 uses the Keychain key (account huawei-360-mac)
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/make-app.sh
VERSION=${VERSION:-0.0.0-dev}
ZIP="dist/Huawei-360-$VERSION-macOS-arm64.zip"
rm -f "$ZIP" "$ZIP.sha256" dist/appcast.xml
ditto -c -k --sequesterRsrc --keepParent "dist/Huawei 360.app" "$ZIP"
(cd dist && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
echo "Packaged: $ZIP"

if [ -z "${SPARKLE_ED_PRIVATE_KEY:-}" ] && [ "${APPCAST:-0}" != 1 ]; then
    echo "No Sparkle key: skipping appcast.xml"
    exit 0
fi
FEED=$(mktemp -d)
cp "$ZIP" "$FEED/"
# Release notes shown in the update window = this version's CHANGELOG section.
awk -v v="$VERSION" '$0 ~ "^## \\[" v "\\]" {on=1; next} /^## \[/ {on=0} on' CHANGELOG.md > "$FEED/$(basename "$ZIP" .zip).md"
[ -s "$FEED/$(basename "$ZIP" .zip).md" ] || rm "$FEED/$(basename "$ZIP" .zip).md"
PREFIX=${DOWNLOAD_URL_PREFIX:-https://github.com/rudlinkon/huawei-360-mac/releases/download/v$VERSION/}
GEN=.build/artifacts/sparkle/Sparkle/bin/generate_appcast
common=(--download-url-prefix "$PREFIX" --embed-release-notes --link https://github.com/rudlinkon/huawei-360-mac -o dist/appcast.xml)
if [ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]; then
    printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$GEN" --ed-key-file - "${common[@]}" "$FEED"
else
    "$GEN" --account huawei-360-mac "${common[@]}" "$FEED"
fi
rm -rf "$FEED"
grep -q 'sparkle:edSignature' dist/appcast.xml || { echo "appcast.xml is not signed" >&2; exit 1; }
echo "Appcast: dist/appcast.xml"
