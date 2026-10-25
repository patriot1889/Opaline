# Playback support matrix

Status as of 25 October 2026.

| Codec | DASH / MP4 → generated HLS | DASH / WebM → generated HLS | YouTube native HLS |
|---|---|---|---|
| **AV1** | Implemented; 4K selectable, playback unconfirmed | Unsupported | Accepted when offered; playback unverified |
| **VP9** | Unsupported | **Live playback confirmed**; resolution unverified¹ | 4K60 selected and player ready; sustained playback unconfirmed |

Applies to all supported cells:

| Decoding | Current position |
|---|---|
| **Hardware** | Required by code; actual decoder use hasn’t been measured per session |
| **Software** | No explicit fallback implemented |

¹ WebM support is experimental, disabled by default, and limited to 8-bit SDR profile-0 VP9 with AAC audio. Validation was on Duo; Apple TV playback remains unverified. Connection resets/timeouts and perceptual A/V sync still need investigation. See [WebM playback details](webm-playback.md) for implementation and validation evidence.

Generated HLS remuxes compressed video into fMP4; it does not decode or transcode it. Shared WebM adapter compilation passed for iOS and tvOS.

## Playback selection priorities

The default preferences order is `visionos.hls` → `visionos.range` → `visionos.sabr` → `tv.sabr` → `visionos.webm` → `progressive`. Saved custom orders are preserved. WebM remains disabled by default.

Sources are checked **one at a time in saved order**. For each source, metadata is probed and the highest-frame-rate tier at the selected resolution is prepared. Successful preparation ends discovery immediately; later sources are not probed for quality. There is no separate frame-rate target setting: a working 4K30 source satisfies a 4K selection even if an unvisited source might offer 4K60. Native HLS remains first in the default order, but a saved custom order is authoritative.

If a source only offers lower resolutions, those tiers are retained without starting playback while the next source is checked. If no source can prepare the target resolution, retained candidates are ranked by resolution, frame rate, native delivery (native HLS/MP4 → generated MP4 HLS → remuxed WebM), then source order. Metadata unavailable after a ten-second deadline **per source** becomes a last-resort candidate. Late probe callbacks cannot replace playback or restart discovery.

Each attempted candidate is consumed. Startup preparation failures continue to the next target tier or source before lowering resolution. Runtime recovery refreshes once, then uses remaining target tiers and discovers unvisited sources on demand before falling back to retained lower tiers. A requested tier disappearing between probe and load fails that candidate rather than silently lowering its quality.

Existing per-source hardware/codec checks still determine eligible formats. No software decoder fallback is added. Experimental WebM remains opt-in, and disabled or signed-in-only paths unavailable to the session are excluded. **Auto** retains its 1080p target/cap.
Automatic dubbing does not bypass quality-first source selection. When the selected adaptive source offers a preferred dub, it still chooses it; otherwise original audio can play at the preferred video quality. Manual audio-track choices remain available. Audio-only playback retains the existing source order.

The policy and chain contain no UIKit/platform-specific code and can be referenced directly from the tvOS branch. The iOS preferences screen and registry remain iOS-owned; tvOS should supply its own registry and delivery preferences.

The iOS/tvOS SDK check also compiles this policy and chain. Under complete Swift 6 checking, the callback-based chain/decorator and existing transport code still report concurrency diagnostics; the app currently builds in Swift 5 mode.

Run `bash scripts/check_playback_selection.sh` for sequential early exit, saved source order, frame-rate selection, lower-quality fallback, lazy recovery, cancellation, stale-result, per-source probe deadlines and automatic-dub policy checks.
