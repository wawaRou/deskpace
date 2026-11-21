#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p build
stage=$(mktemp -d "$PWD/build/.compile.XXXXXX")
trap 'rm -rf "$stage"' EXIT
bundle="$PWD/build/Switch Desktop.app"
sdk=$(xcrun --sdk macosx --show-sdk-path)
for arch in arm64 x86_64; do
    xcrun swiftc -O -whole-module-optimization -swift-version 5 \
        -sdk "$sdk" -target "$arch-apple-macos26.0" Sources/*.swift -o "$stage/$arch"
done
mkdir -p "$bundle/Contents/MacOS"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
xcrun lipo -create "$stage/arm64" "$stage/x86_64" -output "$stage/SwitchDesktop"
mv "$stage/SwitchDesktop" "$bundle/Contents/MacOS/SwitchDesktop"
codesign --force --sign - --identifier dev.switchdesktop.prototype "$bundle"
codesign --verify --strict "$bundle"
printf '%s\n' "$bundle"
