#!/bin/zsh
# Builds "Huawei 360.app" (release) into ./dist
set -euo pipefail
cd "$(dirname "$0")/.."
APP="dist/Huawei 360.app"
rm -rf "$APP"
[ -d Vendor/Syphon.xcframework ] || ./scripts/build-syphon.sh
swift build -c release
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
cp .build/release/CV60Viewer "$APP/Contents/MacOS/CV60Viewer"
cp -R Vendor/Syphon.xcframework/macos-arm64/Syphon.framework "$APP/Contents/Frameworks/"
cp .build/release/cv60 dist/cv60
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Huawei 360</string>
  <key>CFBundleIdentifier</key><string>local.cv60.viewer</string>
  <key>CFBundleExecutable</key><string>CV60Viewer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP/Contents/Frameworks/Syphon.framework"
codesign --force --sign - "$APP" dist/cv60
echo "Built: $APP and dist/cv60"
