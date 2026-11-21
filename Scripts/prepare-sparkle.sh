#!/bin/sh
# Print the local SDK path. Keep signing tools at a stable path for Keychain access.
set -eu
cd "$(dirname "$0")/.."
version=2.10.1
digest=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
name="Sparkle-$version.tar.xz"
archive="$PWD/.build/$name"
destination="$PWD/.build/Sparkle-$version-$digest"
if [ -d "$destination" ]; then
    printf '%s\n' "$destination"
    exit 0
fi
mkdir -p .build
stage=$(mktemp -d "$PWD/.build/.sparkle.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
matches_digest() {
    printf '%s  %s\n' "$digest" "$1" | shasum -a 256 -c --status
}
if [ ! -f "$archive" ] || ! matches_digest "$archive"; then
    download="$stage/$name"
    curl --fail --location --silent --show-error --retry 2 \
        "https://github.com/sparkle-project/Sparkle/releases/download/$version/$name" -o "$download"
    matches_digest "$download" || { echo 'Sparkle 下载文件校验失败' >&2; exit 1; }
    mv "$download" "$archive"
fi
mkdir "$stage/sdk"
tar -xf "$archive" -C "$stage/sdk" ./Sparkle.framework ./bin ./LICENSE
# Another concurrent build may have populated the same immutable version.
perl -e 'rename($ARGV[0], $ARGV[1]) or -d $ARGV[1] or die "rename SDK: $!"' "$stage/sdk" "$destination"
printf '%s\n' "$destination"
