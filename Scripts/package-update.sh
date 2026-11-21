#!/bin/sh
# Package an already built (and, if applicable, notarized and stapled) app.
set -eu
cd "$(dirname "$0")/.."
app="$PWD/build/DeskPace.app"
info="$app/Contents/Info.plist"
codesign --verify --deep --strict --all-architectures "$app"
version=$(plutil -extract CFBundleShortVersionString raw "$info")
account=$(plutil -extract CFBundleIdentifier raw "$info")
feed=$(plutil -extract SUFeedURL raw "$info")
repo=https://github.com/wawaRou/deskpace
[ "$feed" = "$repo/releases/latest/download/appcast.xml" ] || { echo '更新源与发布仓库不一致' >&2; exit 1; }
case "$version" in ''|*[!0-9A-Za-z.-]*) echo '版本号无法用于 Release 标签' >&2; exit 1;; esac

stage=$(mktemp -d "$PWD/build/.package.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
sdk=$(Scripts/prepare-sparkle.sh)
tools="$sdk/bin"
public_key=$("$tools/generate_keys" --account "$account" -p)
[ "$public_key" = "$(plutil -extract SUPublicEDKey raw "$info")" ] || { echo '钥匙串中的签名身份与 App 内置更新公钥不一致' >&2; exit 1; }

assets="$stage/assets"
mkdir "$assets"
archive="DeskPace-$version.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$assets/$archive"
"$tools/generate_appcast" --account "$account" --maximum-deltas 0 \
    --download-url-prefix "$repo/releases/download/v$version/" \
    --link "$repo" "$assets"
signature=$(xmllint --xpath 'string(/rss/channel/item/enclosure/@*[local-name()="edSignature"])' "$assets/appcast.xml")
swift - "$public_key" "$signature" "$assets/$archive" <<'SWIFT'
import CryptoKit
import Foundation
guard let keyData = Data(base64Encoded: CommandLine.arguments[1]),
      let signature = Data(base64Encoded: CommandLine.arguments[2]) else { exit(1) }
let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]), options: .mappedIfSafe)
guard key.isValidSignature(signature, for: archive) else { exit(1) }
SWIFT
output="$PWD/build/releases/v$version"
mkdir -p "$output"
cp "$assets/$archive" "$assets/appcast.xml" "$output/"
printf '%s\n' "$output/$archive" "$output/appcast.xml"
