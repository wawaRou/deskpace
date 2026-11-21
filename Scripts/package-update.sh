#!/bin/sh
# Build the current commit with the release certificate, then package it.
set -eu
cd "$(dirname "$0")/.."
commit=$(git rev-parse --verify HEAD)
[ -z "$(git status --porcelain --untracked-files=all)" ] || { echo '工作区有未提交的改动，请先提交再构建发布包' >&2; exit 1; }
# Accessibility access follows the signing certificate. Any other certificate,
# or an ad hoc signature, would make every user grant it again after this update.
# Change this only together with a release note that asks users to grant access again.
release_certificate=fe0ced9a9ea068390a508c677d313bf5a42eeb40
identity=${CODE_SIGN_IDENTITY:-$(git config --local --get deskpace.signingIdentity 2>/dev/null || git config --local --get switchdesktop.signingIdentity 2>/dev/null || true)}
case "$identity" in
    *[!0-9A-Fa-f]*|'') echo '请用发布证书的 40 位指纹配置签名身份，见 docs/releasing.md 的「签名证书」' >&2; exit 1;;
esac
[ "${#identity}" -eq 40 ] || { echo '签名身份不是 40 位证书指纹' >&2; exit 1; }
[ "$(printf '%s' "$identity" | tr 'A-F' 'a-f')" = "$release_certificate" ] || { echo '配置的签名身份不是发布证书' >&2; exit 1; }
mkdir -p build/releases .build
stage=$(mktemp -d "$PWD/build/.package.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
source_dir="$stage/source"
mkdir "$source_dir"
git archive --format=tar --output="$stage/source.tar" "$commit"
tar -xf "$stage/source.tar" -C "$source_dir"
# Share the pinned SDK cache, while keeping source and build products private to this run.
ln -s "$PWD/.build" "$source_dir/.build"
CODE_SIGN_IDENTITY="$identity" "$source_dir/build.sh" >&2
app="$source_dir/build/DeskPace.app"
info="$app/Contents/Info.plist"
codesign -d -r- "$app" 2>&1 | grep -q "certificate leaf = H\"$release_certificate\"" || { echo 'App 的签名证书与发布证书不一致' >&2; exit 1; }
version=$(plutil -extract CFBundleShortVersionString raw "$info")
# The original Sparkle key also verifies updates for existing installations.
account=dev.switchdesktop.prototype
feed=$(plutil -extract SUFeedURL raw "$info")
repo=https://github.com/wawaRou/deskpace
[ "$feed" = "$repo/releases/latest/download/appcast.xml" ] || { echo '更新源与发布仓库不一致' >&2; exit 1; }
case "$version" in ''|*[!0-9A-Za-z.-]*) echo '版本号无法用于 Release 标签' >&2; exit 1;; esac
# Compare only with tags on the release repository. Local trial tags do not count.
GIT_TERMINAL_PROMPT=0 git ls-remote --refs --sort=-v:refname "$repo" 'refs/tags/v*' > "$stage/tags"
if awk -v tag="refs/tags/v$version" '$2 == tag { found=1 } END { exit !found }' "$stage/tags"; then
    echo "v$version 已经发布过，请先更新 Info.plist 中的版本号和构建号" >&2
    exit 1
fi
build=$(plutil -extract CFBundleVersion raw "$info")
if read -r previous_oid previous_ref < "$stage/tags"; then
    GIT_TERMINAL_PROMPT=0 git fetch --quiet --no-tags --no-write-fetch-head "$repo" "$previous_ref"
    previous_build=$(git show "$previous_oid:Resources/Info.plist" | plutil -extract CFBundleVersion raw -) ||
        { echo "无法读取 $previous_ref 的构建号" >&2; exit 1; }
    [ "$build" -gt "$previous_build" ] || { echo "构建号 $build 没有大于 $previous_ref 的 $previous_build" >&2; exit 1; }
fi
sdk=$("$source_dir/Scripts/prepare-sparkle.sh")
tools=$(cd "$sdk/bin" && pwd -P)
public_key=$("$tools/generate_keys" --account "$account" -p)
[ "$public_key" = "$(plutil -extract SUPublicEDKey raw "$info")" ] || { echo '钥匙串中的签名身份与 App 内置更新公钥不一致' >&2; exit 1; }

assets="$stage/assets"
mkdir "$assets"
archive="DeskPace-$version.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$assets/$archive"
# Sparkle extracts archives under a per-user cache shared by all checkouts.
lockf -k "$HOME/Library/Caches/dev.wawarou.deskpace-appcast.lock" \
    "$tools/generate_appcast" --account "$account" --maximum-deltas 0 \
    --download-url-prefix "$repo/releases/download/v$version/" \
    --link "$repo" "$assets"
ed_signature=$(xmllint --xpath 'string(/rss/channel/item/enclosure/@*[local-name()="edSignature"])' "$assets/appcast.xml")
swift - "$public_key" "$ed_signature" "$assets/$archive" <<'SWIFT'
import CryptoKit
import Foundation
guard let keyData = Data(base64Encoded: CommandLine.arguments[1]),
      let signature = Data(base64Encoded: CommandLine.arguments[2]) else { exit(1) }
let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]), options: .mappedIfSafe)
guard key.isValidSignature(signature, for: archive) else { exit(1) }
SWIFT
output="$PWD/build/releases/v$version"
# Publish the two verified files together. Concurrent packagers cannot replace the winner.
swift - "$assets" "$output" <<'SWIFT'
import Darwin
if renamex_np(CommandLine.arguments[1], CommandLine.arguments[2], UInt32(RENAME_EXCL)) != 0 {
    perror("无法发布安装包目录")
    exit(1)
}
SWIFT
printf '%s\n' "$output/$archive" "$output/appcast.xml"
printf '提交：%s\n' "$commit" >&2
