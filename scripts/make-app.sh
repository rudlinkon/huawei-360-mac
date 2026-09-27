#!/bin/zsh
# Builds a self-contained "Huawei 360.app" (release) into ./dist.
# libusb and Syphon are bundled in Contents/Frameworks, so the app runs without Homebrew.
#   VERSION=0.1.0 BUILD_NUMBER=7 ./scripts/make-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${VERSION:-0.0.0-dev}
BUILD_NUMBER=${BUILD_NUMBER:-1}   # Sparkle compares this (CFBundleVersion): must grow with every release
# Sparkle feed: appcast.xml attached to the latest published GitHub release; key from `generate_keys --account huawei-360-mac`
FEED_URL=${FEED_URL:-https://github.com/rudlinkon/huawei-360-mac/releases/latest/download/appcast.xml}
SPARKLE_PUBLIC_KEY=${SPARKLE_PUBLIC_KEY:-xoia175N2lO0vPGoOqS1MbijK+9QBTjwNDdzcwx/IAA=}
APP="dist/Huawei 360.app"
MACOS="$APP/Contents/MacOS"
FW="$APP/Contents/Frameworks"
rm -rf "$APP" dist/cv60
[ -d Vendor/Syphon.xcframework ] || ./scripts/build-syphon.sh
swift build -c release
mkdir -p "$MACOS" "$FW" "$APP/Contents/Resources"
cp .build/release/CV60Viewer .build/release/cv60 "$MACOS/"
cp -R Vendor/Syphon.xcframework/macos-arm64/Syphon.framework "$FW/"
ditto .build/release/Sparkle.framework "$FW/Sparkle.framework"   # keeps its own signature and XPC services

# Bundle libusb (LGPL-2.1: shipped as a separate, replaceable dylib) and point both binaries at it.
LIBUSB_PREFIX=$(brew --prefix libusb)
cp -L "$LIBUSB_PREFIX/lib/libusb-1.0.0.dylib" "$FW/"
chmod u+w "$FW/libusb-1.0.0.dylib"
install_name_tool -id @rpath/libusb-1.0.0.dylib "$FW/libusb-1.0.0.dylib"
cp "$LIBUSB_PREFIX/COPYING" "$APP/Contents/Resources/libusb-COPYING.txt" 2>/dev/null || true
cp Vendor/Syphon-License.txt "$APP/Contents/Resources/Syphon-License.txt"

# App icon: Resources/AppIcon.png (1024², drawn by scripts/generate-icon.swift) -> AppIcon.icns
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
for px in 16 32 128 256 512; do
    sips -z $px $px Resources/AppIcon.png --out "$ICONSET/icon_${px}x${px}.png" >/dev/null
    sips -z $((px * 2)) $((px * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${px}x${px}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"
for bin in "$MACOS/CV60Viewer" "$MACOS/cv60"; do
    old=$(otool -L "$bin" | awk '/libusb-1\.0/ {print $1; exit}')
    install_name_tool -change "$old" @rpath/libusb-1.0.0.dylib "$bin"
    otool -l "$bin" | grep -q '@executable_path/../Frameworks' ||
        install_name_tool -add_rpath @executable_path/../Frameworks "$bin"
done
ln -s "Huawei 360.app/Contents/MacOS/cv60" dist/cv60

# The app can only run where every bundled binary can: take the highest deployment target.
MIN_OS=$(for f in "$MACOS/CV60Viewer" "$FW/libusb-1.0.0.dylib" "$FW/Syphon.framework/Syphon"; do
    vtool -show-build "$f" | awk '/minos/ {print $2}'; done | sort -V | tail -1)

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Huawei 360</string>
  <key>CFBundleDisplayName</key><string>Huawei 360</string>
  <key>CFBundleIdentifier</key><string>local.cv60.viewer</string>
  <key>CFBundleExecutable</key><string>CV60Viewer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>SUFeedURL</key><string>$FEED_URL</string>
  <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict></plist>
PLIST

# Ad-hoc signature, inside-out (no Developer ID available).
codesign --force --sign - "$FW/libusb-1.0.0.dylib" "$FW/Syphon.framework" "$MACOS/cv60"
codesign --force --sign - "$APP"
echo "Built: $APP (version $VERSION build $BUILD_NUMBER, macOS $MIN_OS+) and dist/cv60"
