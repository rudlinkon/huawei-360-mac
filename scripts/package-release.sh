#!/bin/zsh
# Builds the app and zips it for a GitHub release: dist/Huawei-360-<version>-macOS-arm64.zip (+ .sha256)
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/make-app.sh
VERSION=${VERSION:-0.0.0-dev}
ZIP="dist/Huawei-360-$VERSION-macOS-arm64.zip"
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --sequesterRsrc --keepParent "dist/Huawei 360.app" "$ZIP"
(cd dist && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
echo "Packaged: $ZIP"
