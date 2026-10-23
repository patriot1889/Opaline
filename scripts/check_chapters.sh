#!/bin/bash
# Compile the shipping Foundation-only chapter/model/request sources with fixture dependencies.
# No network is used unless OPALINE_CHAPTER_PROBE=1 is explicitly supplied.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CHECK_TMP=$(mktemp -d /tmp/opaline-chapter-checks.XXXXXX)
trap 'rm -rf "$CHECK_TMP"' EXIT
cat \
  "$ROOT/Opaline/Core/API/Models/VideoChapter.swift" \
  "$ROOT/Opaline/Core/API/Models/WatchPage.swift" \
  "$ROOT/Opaline/Core/API/Parsing/VideoChapterParser.swift" \
  "$ROOT/Opaline/Core/Common/CancellationToken.swift" \
  "$ROOT/Opaline/Core/Config/HTTPConstants.swift" \
  "$ROOT/Opaline/Core/API/InnertubeKeys.swift" \
  "$ROOT/Opaline/Core/API/InnertubeContexts.swift" \
  "$ROOT/Opaline/Core/Transport/HTTPTransport.swift" \
  "$ROOT/Opaline/Core/Transport/StreamingSession.swift" \
  "$ROOT/Opaline/Core/Transport/URLSessionTransport.swift" \
  "$ROOT/Opaline/Core/API/APIClient.swift" \
  "$ROOT/Opaline/Core/API/InnertubeRequestExecutor.swift" \
  "$ROOT/Opaline/Core/API/InnertubeClient+Chapters.swift" \
  "$ROOT/scripts/chapter_checks.swift" > "$CHECK_TMP/main.swift"
swiftc -swift-version 5 -module-cache-path /tmp/opaline-chapter-module-cache \
  "$CHECK_TMP/main.swift" -o "$CHECK_TMP/checks"
"$CHECK_TMP/checks" "$ROOT/scripts/fixtures/chapters-LGA4ZFr-hfo.json"
