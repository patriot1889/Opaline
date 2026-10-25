#!/bin/bash
# Exercise the shipping candidate policy, chain and protocol defaults on macOS.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CHECK_TMP=$(mktemp -d /tmp/opaline-selection.XXXXXX)
trap 'rm -rf "$CHECK_TMP"' EXIT
cat "$ROOT/Opaline/Core/Playback/VideoSource.swift" \
    "$ROOT/Opaline/Core/Playback/PlaybackCandidate.swift" \
    "$ROOT/Opaline/Core/Common/CancellationToken.swift" \
    "$ROOT/Opaline/Core/Playback/Sources/FallbackChainSource.swift" \
    "$ROOT/Opaline/Core/Playback/Sources/AutoDubSource.swift" \
    "$ROOT/scripts/playback_selection_support.swift" \
    "$ROOT/scripts/playback_selection_checks.swift" > "$CHECK_TMP/main.swift"
swiftc -swift-version 5 -module-cache-path /tmp/opaline-selection-module-cache \
    "$CHECK_TMP/main.swift" -o "$CHECK_TMP/checks"
"$CHECK_TMP/checks"
