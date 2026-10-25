#!/bin/bash
# Real URLSession streaming against the shipping loopback server; no internet.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CHECK_TMP=$(mktemp -d /tmp/opaline-webm-http-checks.XXXXXX)
trap 'rm -rf "$CHECK_TMP"' EXIT
cat "$ROOT/Opaline/Core/Config/HTTPConstants.swift" \
    "$ROOT/Opaline/Core/Common/CancellationToken.swift" \
    "$ROOT/Opaline/Core/Transport/HTTPTransport.swift" \
    "$ROOT/Opaline/Core/Transport/StreamingSession.swift" \
    "$ROOT/Opaline/Core/Transport/URLSessionTransport.swift" \
    "$ROOT/Opaline/Core/Playback/SABR/LocalMediaServer.swift" \
    "$ROOT/Opaline/Core/Playback/SABR/LocalMediaServer+HTTP.swift" \
    "$ROOT/Opaline/Core/Playback/SABR/Data+Slice.swift" \
    "$ROOT"/Opaline/Core/Playback/WebM/*.swift \
    "$ROOT/scripts/webm_http_checks.swift" > "$CHECK_TMP/main.swift"
swiftc -swift-version 5 -module-cache-path /tmp/opaline-webm-module-cache \
    "$CHECK_TMP/main.swift" -o "$CHECK_TMP/checks"
"$CHECK_TMP/checks" "$ROOT/scripts/fixtures/webm/vp9-sdr.webm"
