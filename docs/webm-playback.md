# Shared WebM playback groundwork

This first slice demuxes compressed VP9 packets from bounded WebM buffers. It does not enable WebM formats in the playback chain, fetch media, create CoreMedia samples, or remux into MP4 yet.

## Shared ownership

The implementation lives in `Opaline/Core/Playback/WebM/`. All five Swift files import only Foundation, have no platform conditionals, and do not depend on app services, UIKit, AVFoundation, VideoToolbox, or a playback setting. Models contain immutable values and are Sendable.

The iOS synchronized source group picks up these files automatically. The `tvos` branch already uses explicit upstream source references in `OpalineTV.xcodeproj`; when integrating this slice there, add these same files to its shared sources group and compile sources:

- `EBMLReader.swift`
- `WebMPacket.swift`
- `WebMInitialization.swift`
- `WebMCue.swift`
- `WebMCluster.swift`

Do not copy them into `OpalineTV/`. The platform build check compiles the exact same on-disk files for iOS 15 and tvOS 17 deployment targets. No tvOS project is introduced on the iOS branch and no existing upstream files are reorganized.

Hardware decoder registration, profile eligibility and rendering remain adapter responsibilities. A parser compiling on tvOS does not imply that an Apple TV can hardware-decode VP9.

## Buffer contracts

`WebMInitialization.parse` accepts a file prefix beginning with EBML and containing Segment, Info and Tracks. A declared Segment may extend beyond that prefix or have unknown size. The parser identifies a single VP9 video track, retains CodecPrivate and scalar Colour metadata, and reports the absolute file offset of the Segment payload. It does not parse codec-private feature bytes into a decoder configuration yet.

`WebMCue.parse` accepts one complete Cues element, the parsed initialization and the file length. CueClusterPosition is relative to Segment payload, so the parser converts it into a checked absolute file offset. Cue times are converted to integer nanoseconds using TimecodeScale; other tracks' cues are ignored. Relative block positions are retained but not yet used for seeking.

`WebMCluster.parse` accepts exactly one complete Cluster. Unknown-sized Clusters require an externally bounded buffer, normally obtained from adjacent cue positions. It returns compressed packet bytes in file order, signed relative timestamps converted to nanoseconds, durations when present, sync flags and invisible-frame flags. Other tracks are ignored. Invisible reference packets remain in the output with zero presentation duration; they are not discarded or assembled into MP4 superframes here.

Offsets inside a supplied Data buffer are count-relative, including when the Data has a nonzero startIndex. File offsets are Int64. Checked arithmetic rejects timestamp and file-offset overflow. Truncation throws; callers must obtain the complete required range before retrying. There is no mutable global state, I/O or unbounded recursive element walking.

The first slice supports unlaced SimpleBlock and BlockGroup video. It explicitly rejects video lacing, encoded/encrypted tracks, non-default track timestamp scaling, track offsets/codec delays, codec-state changes, BlockAdditions and HDR mastering metadata. Those features must be implemented or remain rejected before their formats enter playback. Preserving scalar colour fields is not equivalent to HDR playback support.

## Verification

Run the host fixture and malformed-input checks with:

```sh
bash scripts/check_webm.sh
```

The checked-in 32×32 SDR VP9 fixture was generated locally from FFmpeg's test pattern. Golden ffprobe output independently verifies every compressed packet SHA-256, timestamp and keyframe flag. The tests also verify cue locations against actual Cluster headers, nonzero Data startIndex, signed block times, BlockGroup timing, other tracks, unknown-sized bounded elements, unsupported features, arithmetic overflow and truncated input. FFmpeg is not required to run these checks.

To verify shared SDK compatibility, install XcodeGen and XcodeBuildMCP, select installed simulator IDs, and run:

```sh
bash scripts/check_webm_platforms.sh <iOS-simulator-id> <tvOS-simulator-id>
```

This creates temporary framework targets referencing the shared files directly, with Swift 5 language mode and complete concurrency checking. It does not modify either app project or require signing.

## Next slice

Add cue-based range selection and a bounded fetching adapter over the existing HTTPTransport. After that, translate VP9 codec metadata and packet timing into CoreMedia format descriptions and compressed sample buffers for AVAssetWriter passthrough. The earlier device spike validated Apple's VP9 fragment writer using MP4-derived compressed samples; it did not validate a direct WebM-to-writer adapter.

Seeking, superframe handling, cancellation, quality/audio changes, SABR delivery, 4K and HDR each need verification before enabling this delivery. Keep existing MP4/SIDX and native HLS selection unchanged until those checks pass.

References: [WebM container guidelines](https://www.webmproject.org/docs/container/), [VP9 MP4 binding](https://www.webmproject.org/vp9/mp4/).
