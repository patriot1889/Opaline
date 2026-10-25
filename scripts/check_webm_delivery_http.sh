#!/bin/bash
# Real range transport -> cue remux -> loopback HLS resources, with AAC rendition.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CHECK_TMP=$(mktemp -d /tmp/opaline-webm-delivery-http.XXXXXX)
trap 'rm -rf "$CHECK_TMP"' EXIT
cat "$ROOT/Opaline/Core/Config/HTTPConstants.swift" \
    "$ROOT/Opaline/Core/Common/CancellationToken.swift" \
    "$ROOT/Opaline/Core/Transport/HTTPTransport.swift" \
    "$ROOT/Opaline/Core/Transport/StreamingSession.swift" \
    "$ROOT/Opaline/Core/Transport/URLSessionTransport.swift" \
    "$ROOT/Opaline/Core/Playback/SABR/LocalMediaServer.swift" \
    "$ROOT/Opaline/Core/Playback/SABR/LocalMediaServer+HTTP.swift" \
    "$ROOT/Opaline/Core/Playback/SABR/Data+Slice.swift" \
    "$ROOT/Opaline/Core/Playback/HLSPlaylistLoader.swift" \
    "$ROOT/Opaline/Core/Playback/HLSGenerator.swift" \
    "$ROOT/Opaline/Core/Playback/HLSGenerator+Sidx.swift" \
    "$ROOT"/Opaline/Core/Playback/WebM/*.swift \
    "$ROOT"/Opaline/Core/Playback/WebM/Apple/*.swift \
    "$ROOT/scripts/webm_delivery_http_checks.swift" > "$CHECK_TMP/main.swift"
swiftc -swift-version 5 -module-cache-path /tmp/opaline-webm-module-cache \
    "$CHECK_TMP/main.swift" -o "$CHECK_TMP/checks"
"$CHECK_TMP/checks" "$ROOT/scripts/fixtures/webm"
