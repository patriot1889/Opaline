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

| Priority | Preference | Behavior |
|---|---|---|
| 1 | Chosen quality | Try every enabled, eligible path at the highest advertised resolution within the Wi-Fi/cellular quality setting before stepping down. |
| 2 | Frame rate | Prefer the higher advertised frame rate at the same resolution. |
| 3 | Native delivery | At equal resolution and frame rate, prefer native HLS/MP4, then MP4 through generated HLS, then WebM remuxing through generated HLS. |
| 4 | Source order | The order in Playback sources breaks ties within a delivery group. |

This is a delivery preference, not a new codec ranking. Existing per-source hardware/codec checks and codec preferences still determine eligible formats. No software decoder fallback is added. Experimental WebM remains opt-in, and disabled or signed-in-only paths unavailable to the session are excluded as before. The current **Auto** quality setting retains its existing 1080p cap.

The chain probes enabled sources for quality metadata before preparing playback, with a ten-second discovery deadline. Sources whose metadata is unavailable remain last-resort candidates after known quality tiers. A requested tier disappearing between probe and load fails that candidate instead of silently lowering its quality. Startup preparation failures and explicit chain advancement continue through the ranked candidates; after playback starts, recovery refreshes once and then consumes the remaining ranked candidates.

Automatic dubbing does not bypass quality-first source selection. When the selected adaptive source offers a preferred dub, it still chooses it; otherwise original audio can play at the preferred video quality. Manual audio-track choices remain available. Audio-only playback retains the existing source order.

The policy and chain contain no UIKit/platform-specific code and can be referenced directly from the tvOS branch. The iOS preferences screen and registry remain iOS-owned; tvOS should supply its own registry and delivery preferences.

The iOS/tvOS SDK check also compiles this policy and chain. Under complete Swift 6 checking, the callback-based chain/decorator and existing transport code still report concurrency diagnostics; the app currently builds in Swift 5 mode.

Run `bash scripts/check_playback_selection.sh` for ranking, fallback, cancellation, stale-result, discovery deadline and automatic-dub policy checks.
