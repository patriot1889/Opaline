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
