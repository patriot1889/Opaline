# Live chapter probe: LGA4ZFr-hfo

Verified on 21 October 2026 using the shared iOS API/playback implementation compiled into the tvOS 26.2 simulator. The session was anonymous. This tests the existing code against YouTube, rather than reproducing its requests in an unrelated script.

| Source | Result |
| --- | --- |
| `InnertubeClient.fetchWatchPage`, WEB `/next` | Five structured chapters, exposed in three response locations |
| `executeWatchNext`, TVHTML5 `/next`, without credentials | No chapter entries |
| VISIONOS `/player` used by the playback chain | Playable response, no chapter entries |
| Actual prepared `visionos.range` AVAsset | No chapter metadata or chapter locales |
| Original video MP4, itag 137 | Playable; no chapter metadata or chapter locales |
| Original audio MP4, itag 140 | Playable; no chapter metadata or chapter locales |

The media duration was 720.953 seconds. The parsed WatchPage had an empty title/description in this run; structured chapters were nevertheless present in the raw WEB response. The current WatchPage and DirectPlaybackInfo models have no chapter field.

## Chapters returned

| Start | Title |
| --- | --- |
| 0:00 | Intro |
| 2:19 | How does compression work? |
| 5:02 | It's pronounced 'gif' |
| 6:45 | Where did it go? |
| 11:48 | Credits |

Exact start times are supplied as `timeRangeStartMillis` under:

```
playerOverlays.playerOverlayRenderer.decoratedPlayerBarRenderer
.decoratedPlayerBarRenderer.playerBar.multiMarkersPlayerBarRenderer
.markersMap[0].value.chapters[].chapterRenderer
```

The same chapters also appear under engagement panels as `macroMarkersListItemRenderer` entries with title and `timeDescription`.

For this video, parsing WEB watch-page metadata is sufficient for timeline markers. No stream chapter metadata was found, including in the original video/audio assets before the app's HLS wrapping. This does not establish chapter availability for other videos, clients, or authenticated responses.

## Reproduce

`OpalineTVTests/ChapterProbeTests.swift` is opt-in and skips during ordinary tests:

```sh
xcodebuildmcp simulator test \
  --project-path OpalineTV.xcodeproj --scheme OpalineTV \
  --simulator-id 9337E6F9-23F3-4CB9-B795-80AE558A6C45 \
  --derived-data-path /tmp/opaline-tv-build \
  --json '{"extraArgs":["-only-testing:OpalineTVTests/ChapterProbeTests"],"testRunnerEnv":{"OPALINE_CHAPTER_PROBE":"1"}}'
```

The probe attaches its report to the xcresult and writes `/tmp/opaline-chapter-probe.json`. The checked-in JSON records this run, excluding credentials and signed media URLs. The probe resolves media and reads metadata without playing it or starting watch-history tracking.
