#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
stage=$(mktemp -d "${TMPDIR:-/tmp}/switch-desktop-test.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
xcrun swiftc -O -swift-version 5 -parse-as-library \
    Sources/DisplayFeedback.swift Sources/NativeSpaces.swift Sources/SwipeEngine.swift Sources/SwipePayload.swift Sources/TailCurve.swift \
    Tests/*.swift -o "$stage/MotionProbe"
"$stage/MotionProbe" "$@"
