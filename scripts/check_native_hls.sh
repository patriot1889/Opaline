#!/bin/bash
# Compile the shipping native HLS source with fixture API/transport dependencies.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CHECK_TMP=$(mktemp -d /tmp/opaline-native-hls-checks.XXXXXX)
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
  "$ROOT/Opaline/Core/Common/CancellationToken.swift" \
  "$ROOT/Opaline/Core/Transport/HTTPTransport.swift" \
  "$ROOT/Opaline/Core/Playback/VideoSource.swift" \
  "$ROOT/Opaline/Core/Playback/AV1Support.swift" \
  "$ROOT/Opaline/Core/Playback/NativeHLSCodecs.swift" \
  "$ROOT/Opaline/Core/Playback/LiveHLSVariants.swift" \
  "$ROOT/Opaline/Core/Playback/HLSGenerator.swift" \
  "$ROOT/Opaline/Core/Playback/HLSPlaylistLoader.swift" \
  "$ROOT/Opaline/Core/Playback/Sources/NativeHLSSource.swift" \
  "$ROOT/scripts/native_hls_checks.swift" > "$CHECK_TMP/main.swift"
swiftc -swift-version 5 -module-cache-path /tmp/opaline-native-hls-module-cache \
  "$CHECK_TMP/main.swift" -o "$CHECK_TMP/checks"
"$CHECK_TMP/checks"
