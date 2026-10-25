#!/bin/bash
# Host CoreMedia/AVAssetWriter passthrough checks; no network or FFmpeg required.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CHECK_TMP=$(mktemp -d /tmp/opaline-webm-apple.XXXXXX)
trap 'rm -rf "$CHECK_TMP"' EXIT
cat "$ROOT/Opaline/Core/Config/HTTPConstants.swift" \
    "$ROOT/Opaline/Core/Common/CancellationToken.swift" \
    "$ROOT/Opaline/Core/Transport/HTTPTransport.swift" \
    "$ROOT"/Opaline/Core/Playback/WebM/*.swift \
    "$ROOT"/Opaline/Core/Playback/WebM/Apple/*.swift \
    "$ROOT/scripts/webm_checks.swift" \
    "$ROOT/scripts/webm_vp9_checks.swift" \
    "$ROOT/scripts/webm_superframe_checks.swift" \
    "$ROOT/scripts/webm_delivery_plan_checks.swift" \
    "$ROOT/scripts/webm_apple_checks.swift" \
    "$ROOT/scripts/webm_delivery_checks.swift" > "$CHECK_TMP/main.swift"
swiftc -swift-version 5 \
    -module-cache-path /tmp/opaline-webm-module-cache "$CHECK_TMP/main.swift" -o "$CHECK_TMP/checks"
"$CHECK_TMP/checks" "$ROOT/scripts/fixtures/webm" "$CHECK_TMP"
