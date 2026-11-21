#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
stage=$(mktemp -d "${TMPDIR:-/tmp}/deskpace-test.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
# The gesture engine lives directly in Sources/. The menu bar app in
# Sources/App/ needs SwiftUI and Sparkle, so the probe leaves it out.
xcrun swiftc -O -swift-version 5 -parse-as-library Sources/*.swift Tests/*.swift -o "$stage/MotionProbe"
"$stage/MotionProbe" "$@"
