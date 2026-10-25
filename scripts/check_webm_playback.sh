#!/bin/bash
# Full shared WebM source composition over local fixtures; opens loopback only.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CHECK_TMP=$(mktemp -d /tmp/opaline-webm-playback.XXXXXX)
trap 'rm -rf "$CHECK_TMP"' EXIT
python3 - "$ROOT" "$CHECK_TMP" <<'PY'
import json, pathlib, sys
root, temporary = map(pathlib.Path, sys.argv[1:])
files = json.loads((root / 'scripts/webm_playback_sources.json').read_text())
sources = [root / file for file in files]
sources += sorted((root / 'Opaline/Core/Playback/WebM').rglob('*.swift'))
sources += sorted((root / 'Opaline/Core/Playback/WebMPlayback').glob('*.swift'))
sources += [root / 'scripts/webm_playback_support.swift', root / 'scripts/webm_playback_checks.swift']
(temporary / 'main.swift').write_text('\n'.join(path.read_text() for path in sources))
PY
swiftc -swift-version 5 -module-cache-path /tmp/opaline-webm-module-cache \
    "$CHECK_TMP/main.swift" -o "$CHECK_TMP/checks"
"$CHECK_TMP/checks" "$ROOT/scripts/fixtures/webm"
