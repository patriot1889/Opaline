# Shared WebM playback groundwork

The shared layer demuxes compressed VP9 packets, fetches cue-bounded media ranges over HTTPTransport and converts a finite SDR profile-0 batch into fragmented MP4 using CoreMedia and AVAssetWriter passthrough. WebM formats remain disabled in the playback chain.

## Shared ownership

The implementation lives in `Opaline/Core/Playback/WebM/`. The parser, range fetcher and VP9 configuration files at the directory root import only Foundation. The `Apple/` subdirectory contains the CoreMedia/AVFoundation adapter, shared directly by iOS and tvOS. Neither layer imports UIKit or depends on app playback settings or platform conditionals. The parser is standalone; the range adapter depends on the shared HTTPTransport, HTTP header constants and CancellationToken. Models contain immutable values and are Sendable.

The iOS synchronized source group picks up these files automatically. The `tvos` branch already uses explicit upstream source references in `OpalineTV.xcodeproj`; when integrating this slice there, add these same files to its shared sources group and compile sources:

- `EBMLReader.swift`
- `WebMPacket.swift`
- `WebMInitialization.swift`
- `WebMCue.swift`
- `WebMCluster.swift`
- `WebMByteRange.swift`
- `WebMClusterIndex.swift`
- `WebMClusterSequence.swift`
- `WebMRangeFetcher.swift`
- `WebMRangeFetcher+Response.swift`
- `WebMVP9Header.swift`
- `WebMVP9Configuration.swift`
- `Apple/WebMVP9Samples.swift`
- `Apple/WebMVP9Fragments.swift`
- `Apple/WebMVP9FragmentWriter.swift`

The tvOS target already references the transport, header constants and cancellation files used by the adapter. Those existing shared references must remain in its compile sources.

Do not copy them into `OpalineTV/`. The platform build check compiles the exact same on-disk files for iOS 15 and tvOS 17 deployment targets. No tvOS project is introduced on the iOS branch and no existing upstream files are reorganized.

Hardware decoder registration, profile eligibility and rendering remain adapter responsibilities. A parser compiling on tvOS does not imply that an Apple TV can hardware-decode VP9.

## Buffer contracts

`WebMInitialization.parse` accepts a file prefix beginning with EBML and containing Segment, Info and Tracks. A declared Segment may extend beyond that prefix or have unknown size. The parser identifies a single VP9 video track, retains CodecPrivate and scalar Colour metadata, and reports the absolute file offset of the Segment payload. The separate VP9 configuration adapter parses codec-private feature bytes when creating a decoder configuration.

`WebMCue.parse` accepts one complete Cues element, the parsed initialization and the file length. CueClusterPosition is relative to Segment payload, so the parser converts it into a checked absolute file offset. Cue times are converted to integer nanoseconds using TimecodeScale; other tracks' cues are ignored. Relative block positions are retained but not yet used for seeking.

`WebMCluster.parse` accepts exactly one complete Cluster. Unknown-sized Clusters require an externally bounded buffer, normally obtained from adjacent cue positions. It returns compressed packet bytes in file order, signed relative timestamps converted to nanoseconds, durations when present, sync flags and invisible-frame flags. Other tracks are ignored. Invisible reference packets remain in the output with zero presentation duration; they are not discarded or assembled into MP4 superframes here.

Offsets inside a supplied Data buffer are count-relative, including when the Data has a nonzero startIndex. File offsets are Int64. Checked arithmetic rejects timestamp and file-offset overflow. Truncation throws; callers must obtain the complete required range before retrying. There is no mutable global state, I/O or unbounded recursive element walking.

The first slice supports unlaced SimpleBlock and BlockGroup video. It explicitly rejects video lacing, encoded/encrypted tracks, non-default track timestamp scaling, track offsets/codec delays, codec-state changes, BlockAdditions and HDR mastering metadata. Those features must be implemented or remain rejected before their formats enter playback. Preserving scalar colour fields is not equivalent to HDR playback support.

## Cue-based fetching

`WebMClusterIndex` groups cues sharing a Cluster offset and produces inclusive byte ranges ending immediately before the next distinct cue's Cluster, or at the file's last byte. Seek selection uses the preceding cue; positions before the first cue select the first entry, and positions after the final cue select the final entry. Negative times and malformed/unsorted cue positions are rejected.

One cue span can contain several Clusters, because not every Cluster necessarily has a keyframe cue. `WebMClusterSequence` walks all Cluster boundaries within the range, including bounded unknown-sized Clusters. It never searches compressed payloads for magic byte sequences. Known-sized trailing Cues, Tags, SeekHead and global padding/checksum elements are skipped; track metadata changes are rejected.

`WebMRangeFetcher` takes an injected transport, an already resolved media URL, client headers and the expected file length. `open` validates both initialization/index ranges, fetches those ranges sequentially, and returns initialization metadata plus the cue index. `fetchPackets` fetches one selected entry and demuxes its Cluster sequence. URLs, authentication/signature solving and retry policy remain the delivery owner's responsibility.

Requests use the playback transport with automatic cookies disabled. The adapter replaces any caller Range and Accept-Encoding headers with its exact inclusive range and `identity`. It requires HTTP 206, an exact Content-Range matching both offsets and the expected total length, and exactly the requested number of bytes. Content-Length, when supplied, must agree. Compressed, ambiguous, shifted, truncated and stale responses fail rather than being treated as media.

The default limit is 16 MiB per requested range, configurable at construction. Over-budget ranges fail before networking. The adapter buffers chunks only up to the requested size and stops streaming on overflow. The production URLSessionTransport implements streaming with early termination; a transport using HTTPTransport's send-based fallback can still buffer the upstream response before invoking the adapter, so use a genuine streaming transport for network memory bounds. The caller controls the number of simultaneous ranges and any cache budget.

Each request owns a lock-protected buffer; there is no mutable global or active-playback state. Cancellation uses the existing CancellationToken contract: pre-cancelled work does not start, arriving chunks stop when cancellation is observed, and cancelled operations suppress their completion callback. Completion runs on the transport's callback queue, outside the buffer lock. The playback adapter will own tokens and generation checks when integrating seeks and quality changes.

## Apple passthrough adapter

`WebMVP9Configuration` validates WebM CodecPrivate TLVs and checks profile, dimensions, range and colour against an actual VP9 keyframe header. It creates the version-1 `vpcC` FullBox payload. Missing level and colour tags remain unspecified; the adapter does not advertise an invented level or HDR capability. Nondefault WebM crop/display geometry, stereo and alpha are rejected by initialization parsing so they cannot silently disappear during conversion. That focused parser change is shared by both platforms and requires no iOS project restructuring.

`WebMVP9Samples` creates CoreMedia-owned copies of compressed packets and one ready sample buffer per supported frame. It preserves integer nanosecond PTS/DTS and sync attachments. Explicit packet durations take priority; otherwise the following PTS supplies duration, with DefaultDuration required for a final sample lacking an explicit duration. Duplicate, decreasing, negative or overflowing timestamps, overlapping explicit durations and an unknown final duration fail. A batch must begin with a matching visible keyframe; later keyframes must keep the same configuration.

The current adapter supports only visible, single-frame, 8-bit profile-0 SDR packets. Invisible reference frames, show-existing frames and indexed superframes are explicitly rejected, including when WebM flags contradict the bitstream. The parser still preserves these packets. Full interframe reference/size validation and superframe handling remain prerequisites for accepting general YouTube streams. Rejecting unsupported packets prevents this limited adapter from silently discarding reference data.

`WebMVP9FragmentWriter.write` owns a finite job on a private serial queue, respects AVAssetWriter input readiness and emits Apple HLS initialization/media fragments using compressed passthrough. Its two-second target waits for keyframes. Segment reports retain absolute cue start times; sample times are not rebased. Input is capped at 4,096 packets and 16 MiB, retained output at 32 MiB, and the job has a 30-second deadline. These bounds cover adapter-owned samples/output; AVAssetWriter manages its own internal allocations. The delegate collector uses a lock because Apple may call it from another queue.

Completion is delivered once on the job queue, including failure, deadline and cancellation. This finite writer's `cancel()` reports `WebMRemuxError.cancelled`; unlike transport CancellationToken, it does not silence completion. Cancellation after completion has no effect. Completion releases retained samples and collector data. Callers must still bound concurrent jobs and use playback-generation checks before publishing results. The portable readiness API supports the existing iOS 15/tvOS 17 deployment targets; the macOS 27 host compiler reports its new deprecations.

## Verification

Run the host fixture and malformed-input checks with:

```sh
bash scripts/check_webm.sh
```

The checked-in 32×32 SDR VP9 fixture was generated locally from FFmpeg's test pattern. Golden ffprobe output independently verifies every compressed packet SHA-256, timestamp and keyframe flag. The checks also exercise metadata-only opening, ranged packet reconstruction, seek boundaries, duplicate cue positions, multi-Cluster spans, false Cluster markers inside compressed data, HTTP range/status/header validation, early size limits, transport errors, cancellation and repeated callbacks. The parser's malformed-input coverage includes nonzero Data startIndex, signed times, unknown sizes, unsupported features, overflow and truncation. FFmpeg and network access are not required to run these checks.

For CoreMedia and AVAssetWriter passthrough checks on a Mac, run:

```sh
bash scripts/check_webm_apple.sh
```

This checks exact CoreMedia bytes/timing/sync flags, unsupported codec/colour/frame layouts, final duration requirements, cancellation, exactly-once completion, nonzero cue starts verified through fragment reports and structural `tfdt`/`mdhd` inspection, and Apple MP4 readback of all 30 fixture packets. Empty AVAssetReader boundary markers are excluded from compressed-packet counts. AVURLAsset normalizes a standalone nonzero-start fragment to an asset-local origin during readback; the underlying fragment decode time remains absolute.

The larger `vp9-sdr-playback.webm` fixture is intended for hardware playback checks. On the Duo (iOS 27.1), a temporary diagnostic app fed this file through the shared parser/writer and served the output with the existing loopback HLS generator/server. AVPlayer decoded 25 distinct frames through 2.49 seconds, crossing the fragment boundary with no playback error. The 32×32 parser fixture produced valid MP4 readback but failed playback on that device with decoder error -12911; it is not used as evidence of hardware playback. This local test establishes basic video passthrough, not general YouTube, 4K, HDR or tvOS hardware playback support.

For integration with the shipping URLSessionTransport, StreamingSession and loopback media server, run:

```sh
bash scripts/check_webm_http.sh
```

This opens only a local loopback listener, reconstructs all 30 fixture packets through real HTTP 206 requests, fetches a seek-selected range and checks non-2xx propagation. It uses no external service. Host sandbox settings must permit the loopback listener/client.

To verify shared SDK compatibility, install XcodeGen and XcodeBuildMCP, select installed simulator IDs, and run:

```sh
bash scripts/check_webm_platforms.sh <iOS-simulator-id> <tvOS-simulator-id>
```

This creates temporary framework targets referencing the shared files directly, with Swift 5 language mode and complete concurrency checking. It does not modify either app project or require signing.

## Next slice

Handle VP9 superframes, invisible/show-existing reference frames and their decode/presentation timing, then validate representative YouTube WebM packets. Connect bounded range delivery to fragment serving only after that coverage exists.

Audio synchronization, playback seeking/cancellation, quality changes, SABR delivery, 4K, HDR and actual Apple TV decoding still need verification before enabling this delivery. Keep existing MP4/SIDX and native HLS selection unchanged until those checks pass.

References: [WebM container guidelines](https://www.webmproject.org/docs/container/), [VP9 MP4 binding](https://www.webmproject.org/vp9/mp4/).
