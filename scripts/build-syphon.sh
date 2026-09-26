#!/bin/zsh
# Rebuilds Vendor/Syphon.xcframework from source (BSD-licensed, https://github.com/Syphon/Syphon-Framework).
# Needs Xcode's Metal toolchain: xcodebuild -downloadComponent MetalToolchain
set -euo pipefail
cd "$(dirname "$0")/.."
COMMIT=f476167
WORK=.build/syphon
rm -rf "$WORK" Vendor/Syphon.xcframework
git clone -q https://github.com/Syphon/Syphon-Framework.git "$WORK/src"
git -C "$WORK/src" checkout -q "$COMMIT"
xcodebuild -project "$WORK/src/Syphon.xcodeproj" -target Syphon -configuration Release \
    CODE_SIGNING_ALLOWED=NO ARCHS=arm64 SYMROOT="$PWD/$WORK/build" build 2>&1 | grep -E ' error:|BUILD ' || true
mkdir -p Vendor
xcodebuild -create-xcframework -framework "$WORK/build/Release/Syphon.framework" -output Vendor/Syphon.xcframework
cp "$WORK/src/License.txt" Vendor/Syphon-License.txt
echo "Built Vendor/Syphon.xcframework (Syphon $COMMIT)"
