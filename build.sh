#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p build
stage=$(mktemp -d "$PWD/build/.compile.XXXXXX")
trap 'rm -rf "$stage"' EXIT
bundle="$stage/DeskPace.app"
installed="$PWD/build/DeskPace.app"
identity=${CODE_SIGN_IDENTITY:-$(git config --local --get switchdesktop.signingIdentity 2>/dev/null || true)}
if [ -z "$identity" ]; then
    if [ -d "$installed" ] && ! codesign -dv "$installed" 2>&1 | grep -q '^Signature=adhoc$'; then
        printf '%s\n' '已有 App 使用固定签名，请先配置原签名身份。' >&2
        exit 1
    fi
    identity=-
    printf '%s\n' '未配置固定签名身份，本次为临时签名。详见 README 的「更新时保留授权」。' >&2
fi
sdk=$(xcrun --sdk macosx --show-sdk-path)
for arch in arm64 x86_64; do
    xcrun swiftc -O -whole-module-optimization -swift-version 5 \
        -sdk "$sdk" -target "$arch-apple-macos26.0" Sources/*.swift -o "$stage/$arch"
done
iconset="$stage/AppIcon.iconset"
mkdir -p "$iconset"
for points in 16 32 128 256 512; do
    for scale in 1 2; do
        pixels=$((points * scale))
        suffix=""
        if [ "$scale" -eq 2 ]; then suffix="@2x"; fi
        sips -s format png -Z "$pixels" Resources/logo.svg \
            --out "$iconset/icon_${points}x${points}${suffix}.png" >/dev/null
    done
done
iconutil -c icns "$iconset" -o "$stage/AppIcon.icns"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$stage/AppIcon.icns" Resources/logo-menubar.svg "$bundle/Contents/Resources/"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
xcrun lipo -create "$stage/arm64" "$stage/x86_64" -output "$stage/DeskPace"
mv "$stage/DeskPace" "$bundle/Contents/MacOS/DeskPace"
codesign --force --sign "$identity" --identifier dev.switchdesktop.prototype "$bundle"
codesign --verify --strict --all-architectures "$bundle"
if [ -e "$installed" ]; then
    /usr/bin/swift -e '
        import Darwin
        if renamex_np(CommandLine.arguments[1], CommandLine.arguments[2], UInt32(RENAME_SWAP)) != 0 {
            perror("replace app")
            exit(1)
        }
    ' "$bundle" "$installed"
else
    mv "$bundle" "$installed"
fi
printf '%s\n' "$installed"
