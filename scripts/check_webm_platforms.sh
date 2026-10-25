#!/bin/bash
# Compile the same source references against both Apple SDKs, without signing.
# Usage: bash scripts/check_webm_platforms.sh <iOS-simulator-id> <tvOS-simulator-id>
set -euo pipefail
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <iOS-simulator-id> <tvOS-simulator-id>" >&2
    exit 2
fi
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CHECK_TMP=$(mktemp -d /tmp/opaline-webm-platforms.XXXXXX)
trap 'rm -rf "$CHECK_TMP"' EXIT
python3 - "$ROOT" "$CHECK_TMP" <<'PY'
import json
import pathlib
import sys

source_root = pathlib.Path(sys.argv[1]) / "Opaline/Core/Playback/WebM"
shared = ["Opaline/Core/Config/HTTPConstants.swift", "Opaline/Core/Common/CancellationToken.swift",
          "Opaline/Core/Transport/HTTPTransport.swift"]
targets = {}
for name, platform, minimum in [("WebMCoreIOS", "iOS", "15.0"), ("WebMCoreTV", "tvOS", "17.0")]:
    targets[name] = {
        "type": "framework", "platform": platform, "deploymentTarget": minimum,
        "sources": [{"path": str(source_root)}] + [
            {"path": str(pathlib.Path(sys.argv[1]) / source)} for source in shared
        ],
        "settings": {"base": {"PRODUCT_BUNDLE_IDENTIFIER": "test.opaline." + name}},
    }
spec = {
    "name": "WebMCompatibility",
    "settings": {"base": {
        "SWIFT_VERSION": "5.0", "SWIFT_STRICT_CONCURRENCY": "complete",
        "GENERATE_INFOPLIST_FILE": "YES", "CODE_SIGNING_ALLOWED": "NO", "SKIP_INSTALL": "YES",
    }},
    "targets": targets,
}
(pathlib.Path(sys.argv[2]) / "project.json").write_text(json.dumps(spec))
PY
xcodegen generate --spec "$CHECK_TMP/project.json"
xcodebuildmcp simulator build --project-path "$CHECK_TMP/WebMCompatibility.xcodeproj" \
    --scheme WebMCoreIOS --simulator-id "$1" --derived-data-path "$CHECK_TMP/ios-build" --output json
xcodebuildmcp simulator build --project-path "$CHECK_TMP/WebMCompatibility.xcodeproj" \
    --scheme WebMCoreTV --simulator-id "$2" --derived-data-path "$CHECK_TMP/tv-build" --output json
