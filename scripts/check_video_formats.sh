#!/bin/bash
# Exercise the shipping parser with controlled hardware and quality settings.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CHECK_TMP=$(mktemp -d /tmp/opaline-video-format-checks.XXXXXX)
trap 'rm -rf "$CHECK_TMP"' EXIT
cat \
  "$ROOT/Opaline/Core/Config/HTTPConstants.swift" \
  "$ROOT/Opaline/Core/API/InnertubeKeys.swift" \
  "$ROOT/Opaline/Core/API/InnertubeContexts.swift" \
  "$ROOT/Opaline/Core/API/Clients/PlaybackClient.swift" \
  "$ROOT/Opaline/Core/API/Clients/VisionOSClient.swift" \
  "$ROOT/Opaline/Core/API/Clients/SABRClientInfo.swift" \
  "$ROOT/Opaline/Core/Playback/SABR/Protobuf.swift" \
  "$ROOT/Opaline/Core/API/Models/SubtitleTrack.swift" \
  "$ROOT/Opaline/Core/API/Models/DirectPlaybackInfo.swift" \
  "$ROOT/Opaline/Core/API/InnertubeClientPlayerParsing.swift" \
  "$ROOT/scripts/video_format_checks.swift" > "$CHECK_TMP/main.swift"
swiftc -swift-version 5 -module-cache-path /tmp/opaline-video-format-module-cache \
  "$CHECK_TMP/main.swift" -o "$CHECK_TMP/checks"
"$CHECK_TMP/checks"
