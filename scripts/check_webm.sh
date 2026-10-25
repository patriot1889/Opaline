#!/bin/bash
# Foundation-only shared parser checks; no network, simulator or FFmpeg needed.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CHECK_TMP=$(mktemp -d /tmp/opaline-webm-checks.XXXXXX)
trap 'rm -rf "$CHECK_TMP"' EXIT
cat "$ROOT"/Opaline/Core/Playback/WebM/*.swift \
    "$ROOT/scripts/webm_checks.swift" > "$CHECK_TMP/main.swift"
swiftc -swift-version 5 -module-cache-path /tmp/opaline-webm-module-cache \
    "$CHECK_TMP/main.swift" -o "$CHECK_TMP/checks"
"$CHECK_TMP/checks" "$ROOT/scripts/fixtures/webm"
