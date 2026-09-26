#!/bin/zsh
# Builds a self-contained "Huawei 360.app" (release) into ./dist.
# libusb and Syphon are bundled in Contents/Frameworks, so the app runs without Homebrew.
#   VERSION=0.1.0 BUILD_NUMBER=7 ./scripts/make-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${VERSION:-0.0.0-dev}
BUILD_NUMBER=${BUILD_NUMBER:-1}
APP="dist/Huawei 360.app"
MACOS="$APP/Contents/MacOS"
FW="$APP/Contents/Frameworks"
rm -rf "$APP" dist/cv60
[ -d Vendor/Syphon.xcframework ] || ./scripts/build-syphon.sh
swift build -c release
mkdir -p "$MACOS" "$FW" "$APP/Contents/Resources"
cp .build/release/CV60Viewer .build/release/cv60 "$MACOS/"
cp -R Vendor/Syphon.xcframework/macos-arm64/Syphon.framework "$FW/"

# Bundle libusb (LGPL-2.1: shipped as a separate, replaceable dylib) and point both binaries at it.
LIBUSB_PREFIX=$(brew --prefix libusb)
cp -L "$LIBUSB_PREFIX/lib/libusb-1.0.0.dylib" "$FW/"
chmod u+w "$FW/libusb-1.0.0.dylib"
install_name_tool -id @rpath/libusb-1.0.0.dylib "$FW/libusb-1.0.0.dylib"
cp "$LIBUSB_PREFIX/COPYING" "$APP/Contents/Resources/libusb-COPYING.txt" 2>/dev/null || true
cp Vendor/Syphon-License.txt "$APP/Contents/Resources/Syphon-License.txt"
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
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

# Ad-hoc signature, inside-out (no Developer ID available).
codesign --force --sign - "$FW/libusb-1.0.0.dylib" "$FW/Syphon.framework" "$MACOS/cv60"
codesign --force --sign - "$APP"
echo "Built: $APP (version $VERSION build $BUILD_NUMBER, macOS $MIN_OS+) and dist/cv60"
