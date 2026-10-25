# Shared WebM playback groundwork

The shared layer demuxes compressed VP9 packets, fetches cue-bounded media ranges over HTTPTransport and converts SDR profile-0 batches into fragmented MP4 using CoreMedia and AVAssetWriter passthrough, and serves cue ranges on demand through a bounded delivery owner. The `visionos.webm` playback step is registered as an opt-in experiment and remains disabled by default. Existing native HLS, MP4 range and SABR selections are unchanged.

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
- `WebMVP9Superframe.swift`
- `WebMVP9References.swift`
- `WebMVP9AccessUnits.swift`
- `WebMVP9DeliveryPlan.swift`
- `Apple/WebMVP9Samples.swift`
- `Apple/WebMVP9Fragments.swift`
- `Apple/WebMVP9FragmentWriter.swift`
- `Apple/WebMVP9DeliverySegment.swift`
- `Apple/WebMVP9DeliveryJob.swift`
- `Apple/WebMVP9Delivery.swift`

The tvOS target already references the transport, header constants and cancellation files used by the adapter. Those existing shared references must remain in its compile sources.

Do not copy them into `OpalineTV/`. The platform build check compiles the exact same on-disk files for iOS 15 and tvOS 17 deployment targets. No tvOS project is introduced on the iOS branch and no existing upstream files are reorganized.

The playback composition lives separately in `Opaline/Core/Playback/WebMPlayback/`, also shared directly:

- `WebMVP9Formats.swift` and `WebMVP9Level.swift`
- `WebMVP9DeliveryFactory.swift` and `WebMStreamDelivery.swift`
- `WebMPlaybackInput.swift` and `WebMAudioIndex.swift`
- `WebMPlaybackBuilder.swift` and `WebMPlaybackBuilder+Serving.swift`
- `WebMPlaybackSession.swift`

For the tvOS branch, reference these same files plus the shared core and existing AVFoundation/HLS/server/client dependencies. Keep tvOS's step registration and settings in its own configuration; do not copy the iOS registry/settings changes into `OpalineTV/`. Shared upstream integration edits are limited to the separate format catalog/parser, defaulted delivery policy/lifecycle hooks and calls from the existing adaptive source. `DashFormatInfo` and `SidxSegment` gain compiler-checked Sendable conformance for immutable metadata crossing preparation queues. No iOS project or UI is reorganized.

Hardware decoder registration, profile eligibility and rendering remain adapter responsibilities. A parser compiling on tvOS does not imply that an Apple TV can hardware-decode VP9.

## Buffer contracts

`WebMInitialization.parse` accepts a file prefix beginning with EBML and containing Segment, Info and Tracks. A declared Segment may extend beyond that prefix or have unknown size. The parser identifies a single VP9 video track, retains CodecPrivate and scalar Colour metadata, and reports the absolute file offset of the Segment payload. The separate VP9 configuration adapter parses codec-private feature bytes when creating a decoder configuration.

`WebMCue.parse` accepts one complete Cues element, the parsed initialization and the file length. CueClusterPosition is relative to Segment payload, so the parser converts it into a checked absolute file offset. Cue times are converted to integer nanoseconds using TimecodeScale; other tracks' cues are ignored. Relative block positions are retained but not yet used for seeking.

`WebMCluster.parse` accepts exactly one complete Cluster. Unknown-sized Clusters require an externally bounded buffer, normally obtained from adjacent cue positions. It returns compressed packet bytes in file order, signed relative timestamps converted to nanoseconds, explicit BlockDuration values when present, sync flags and invisible-frame flags. DefaultDuration remains on the track, rather than being synthesized as an explicit packet duration. Other tracks are ignored. Invisible reference packets remain in the demuxer output with zero presentation duration. The separate access-unit adapter groups them into MP4 superframes; the demuxer never discards or regroups them.

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

`WebMVP9Samples` creates CoreMedia-owned copies and one ready sample buffer per displayed access unit, retaining preceding invisible frames in a VP9 superframe. It preserves integer nanosecond PTS/DTS and sync attachments. Explicit packet durations take priority; otherwise the following PTS supplies duration, with an explicit batch end boundary supplying the last duration, or DefaultDuration required if neither the boundary nor an explicit final duration is available. A supplied boundary must agree with an explicit final BlockDuration; it cannot silently stretch or truncate it. Duplicate display timestamps, decreasing timestamps, negative or overflowing times, overlapping explicit durations and an unknown final duration fail. Hidden references can share the following display timestamp but cannot cross it. A batch must begin with a matching keyframe and finish on a displayed access unit; later keyframes must keep the same configuration. A hidden keyframe followed by show-existing can form a sync access unit.

The adapter supports 8-bit profile-0 SDR elementary frames, indexed superframes, separately stored invisible reference frames and show-existing frames. `WebMVP9Superframe` validates both index markers, one-to-four-byte little-endian sizes, frame counts and exact payload coverage without scanning compressed bytes. An isolated marker-like final byte remains compressed data. Existing valid indexed packets pass through byte-exactly. `WebMVP9AccessUnits` groups separate hidden references with the next displayed frame in decode order, using that display's PTS/duration, and emits a fresh index when grouping changes. Every access unit must contain exactly one displayed frame at the end and at most eight elementary frames. Trailing hidden references, contradictory WebM flags, multiple displays without individual timing and capacity overruns fail.

The uncompressed-header parser reads reference slots, refresh flags, show-existing indices and explicit/inherited frame dimensions. `WebMVP9References` validates slot availability and fixed dimensions; compressed headers, entropy state and pixels remain Apple's decoder's responsibility. Keyframes initialize all slots, while profile-0 intra-only frames use their implicit studio-range BT.601 colour and explicit refresh mask. Resolution/colour changes, HDR, profiles above zero, and unsupported render-size overrides are rejected. Unindexed concatenated multi-frame payloads are not split by guessing compressed frame boundaries.

The explicit/default duration distinction matters at 30 fps: millisecond WebM timestamps alternate between 33 and 34 ms, while DefaultDuration can be 33,333,333 ns. Treating that default as an explicit BlockDuration falsely creates overlaps. The shared demuxer now preserves only actual BlockDuration on visible packets; the sample builder uses the next display PTS before falling back to DefaultDuration for the last sample. This is a focused change in the inactive shared WebM path, with no effect on existing MP4 or native HLS playback.

`WebMVP9FragmentWriter.write` owns a finite job on a private serial queue, respects AVAssetWriter input readiness and emits Apple HLS initialization/media fragments using compressed passthrough. Its two-second target waits for keyframes. Segment reports retain absolute cue start times; sample times are not rebased. Input is capped at 4,096 packets and 16 MiB, retained output at 32 MiB, and the job has a 30-second deadline. These bounds cover adapter-owned samples/output; AVAssetWriter manages its own internal allocations. The delegate collector uses a lock because Apple may call it from another queue.

Completion is delivered once on the job queue, including failure, deadline and cancellation. This finite writer's `cancel()` reports `WebMRemuxError.cancelled`; unlike transport CancellationToken, it does not silence completion. Cancellation after completion has no effect. Completion releases retained samples and collector data. Callers must still bound concurrent jobs and use playback-generation checks before publishing results. The portable readiness API supports the existing iOS 15/tvOS 17 deployment targets; the macOS 27 host compiler reports its new deprecations.

## On-demand delivery

`WebMVP9DeliveryPlan` turns an opened cue index and an explicit, accurate video end time in nanoseconds into a finite VOD timeline. It requires a zero-based first cue, strictly increasing cue times and at most 32,768 intervals. The end of each interval is the next cue time, with the supplied video end closing the last interval. Do not substitute a rounded display duration when composing video and audio.

`WebMVP9Delivery` takes the existing range fetcher and opened metadata; construction and playlist requests fetch no media. Init/media requests fetch only their selected cue range, normalize its VP9 packets and run a finite passthrough writer. The actual first packet must match the cue time, every packet must precede the interval end, and writer reports must cover the interval exactly. Each job passes the exact end to the sample builder, avoiding accumulated DefaultDuration rounding at independently remuxed cue boundaries. The first successful configuration is pinned; a later cue cannot quietly change dimensions or colour configuration.

Each cue has its own `EXT-X-MAP` and independently generated init/media resources, retaining absolute fragment decode times. A cue can contain several writer fragments; those contiguous fragments are concatenated into that cue's media resource. The playlist uses integer-derived, nine-decimal durations and a distinct UUID path per owner so old video/quality URLs cannot address a replacement owner. Unknown or noncanonical paths fail without transport work. The returned resources contain bytes and MIME types; the existing LocalMediaServer can supply HTTP HEAD/range behavior without changes.

One fetch/remux job runs at a time. Requests for the active cue coalesce; other requests queue. Defaults retain at most two cue results and 32 MiB total cached init/media, with at most 32 pending/active cue completions and a 60-second fetch/remux deadline. The owner rejects cue ranges over 16 MiB before networking, even if the caller configures a larger fetcher; the writer keeps its existing packet/output limits. Cached entries use LRU eviction; a backward seek refetches an evicted range directly. A result exceeding the cache budget fails rather than being retained outside it. Cache bounds exclude bodies already handed to clients/server connections and Apple's own allocations.

All delivery state and callbacks run on a private serial queue. Every accepted load/resource request completes once with a result, including cancellation, timeout and capacity failure. `cancelPendingRequests()` cancels the active generation and queued requests, preserving immutable cached media for a seek. Unique job IDs and terminal job guards prevent late network/writer callbacks from publishing into a new generation. `close()` is terminal: it cancels requests and releases the cache. The playback owner must call it before stopping/replacing the delivery; dropping the owner also cancels underlying work, but callers needing a terminal reply must close explicitly.

The delivery layer emits video resources. Audio can use the existing MP4/SIDX path on the same zero-based timeline, with HLSGenerator supplying the audio playlist and master. A local six-second fixture test serves VP9 via real HTTP range fetch/remux and an independent AAC rendition. Video intervals total exactly 6.0 seconds; AAC totals 6.021333 seconds, within one 1,024-sample AAC frame at 48 kHz. On the Duo, AVPlayer decoded 111 frames through 5.94 seconds across the three independently remuxed cues, reported two item tracks and selected the audible rendition with no playback error. This verifies timeline composition and rendition selection; perceptual A/V offset on real YouTube content still needs validation.

This owner does not resolve YouTube URLs, sign requests, select formats, start a server or create an AVPlayerItem. The playback composition below owns those responsibilities. No tvOS UI/lifecycle/configuration is changed.

## Opt-in playback source

The normal player-response parser now retains `webMVideoFormats` separately. Its MP4/SABR `dashVideoFormat` and `allDashVideoFormats` keep their existing selection rules. A response containing only WebM video plus direct AAC metadata can be parsed without inventing an MP4 selection. The WebM catalog has a default empty value, preserving existing model construction sites. The parser's rejection log now explicitly identifies the MP4/SABR ladder rather than implying that every crossed-out WebM format is unsupported by every delivery.

`StreamDeliveryFactory.playbackInfo` defaults to identity. Only WebMVP9DeliveryFactory projects its supported catalog into the existing adaptive source's active video/audio fields. InnertubeVideoSource applies that policy to real loads and quality probes, then reuses its existing quality, original/dub, caption and progress handling. This avoids copying the adaptive source or changing default MP4/SABR selection.

Eligibility requires registered hardware VP9 support, direct HTTP(S) URLs, bounded and ordered initialization/index metadata, positive video duration/dimensions/rate/bitrate, SDR profile-0 eight-bit VP9 and direct AAC-LC MP4 audio. VP8, Opus, HDR/profile-2 VP9, cipher challenges and clients requiring signature solving are not routed here. Actual WebM headers, track dimensions, reference frames, colour configuration and cue timing are checked during preparation as well; a JSON MIME label alone never makes a packet playable.

`WebMPlaybackBuilder` fetches and validates the AAC index, opens WebM metadata, and prewarms just the cue preceding the requested playhead before preparing an item. AAC must use a complete flat SIDX with zero first offset and presentation origin, nonempty finite segments and in-file byte coverage. The existing HLS generator serves the AAC rendition; the video owner supplies exact cue resources. Resume adds a precise start tag to the video playlist and the existing audio start tag. Normal HTTP playback keeps the shell's usual post-attachment seek contract. Audio-only mode prepares AAC without fetching any WebM bytes.

The prewarmed decoder configuration determines the advertised VP9 level when present; otherwise a declared format level is retained, or a level is estimated from the format's dimensions, frame rate and bitrate using the published level limits. The tested Duo rejected a master advertising undefined level `00` before decoding; the same fixture played when advertised with its inferred level `21`. The estimate is a compatibility hint, not a full bitstream-level conformance or hardware-resolution test. See the [VP9 level definitions](https://www.webmproject.org/vp9/levels/) and [FFmpeg's analogous MP4 level estimation](https://github.com/FFmpeg/FFmpeg/blob/master/libavformat/vpcc.c).

A source cannot know every remuxed byte count before downloading all cues. Each delivery interval now enforces an output allowance of its source bytes plus 1 MiB for indexes/container overhead (in addition to the writer/cache caps). The master advertises a conservative peak from those enforced per-cue bounds plus the measured AAC peak. This avoids an unbounded bandwidth guess without eagerly remuxing the entire file.

`WebMStreamDelivery` owns preparation identity and releases superseded work. The defaulted StreamDelivery.releaseResources hook lets the adaptive source explicitly stop a delivery even if a pending callback retains it; logging captures a label string rather than retaining the delivery. New prepares, release and deinitialization silence stale callbacks, cancel metadata tasks, close the bounded video owner and stop the loopback server. The ready result retains WebMPlaybackSession through the existing resourceLoader lifetime slot; its AVPlayerItem and caller completion are created/delivered on main. This HTTP session does not intercept AVAssetResourceLoader requests. The ready HTTP asset receives the same client media headers as the range transport, including visitor identity.

The iOS registry adds `visionos.webm` / **visionOS · WebM VP9 (experimental)** at the end of the stored order and excludes it from defaultEnabled. To test it, enable that step in the existing playback-chain settings and move it ahead of other working sources (or temporarily leave only that step enabled). No existing preference is changed automatically. A tvOS-owned registry may expose the same factory independently after merging the shared code.

On the Duo, the complete parser → factory → delivery → prepared-item path decoded 111 frames through 5.95 seconds with AAC selected and two item tracks. A second preparation at 2.5 seconds produced its first displayed frame at exactly 2.5 seconds and decoded 64 frames through 5.95 seconds, again without playback errors. These are generated local fixtures served by real HTTP, not live YouTube/4K validation.

The 25 October 2026 Xcode run on the Duo (iOS 27.1) also exercised live YouTube video `U-QiUAMda7Y`: `visionos.webm` resolved successfully, AVPlayer became ready with video and audio tracks, and watchtime positions advanced from 142 to 165 seconds while the local server continued serving WebM-derived fragments. No source fallback or player failure was logged. The log does not identify the played video resolution or measure dropped frames/A/V offset, so it does not establish sustained 4K playback. Connection resets and a timeout were present and remain to be investigated.

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

The larger `vp9-sdr-playback.webm` fixture is intended for physical-device playback checks. On the Duo (iOS 27.1), a temporary diagnostic app fed this file through the shared parser/writer and served the output with the existing loopback HLS generator/server. AVPlayer decoded 25 distinct frames through 2.49 seconds, crossing the fragment boundary with no playback error. The 32×32 parser fixture produced valid MP4 readback but failed playback on that device with decoder error -12911; it is not used as evidence of hardware playback. This local test establishes basic video passthrough, not general YouTube, 4K, HDR or tvOS hardware playback support.

`vp9-altref.webm` adds a six-second, 640×360, 30 fps two-pass clip with 180 displays, 12 indexed superframes and 192 elementary frames. Checked-in ffprobe packet hashes and FFmpeg `vp9_superframe_split` hashes independently verify every frame. Both pre-indexed and separately stored reference layouts normalize to identical access units; Apple MP4 readback preserves all 192 frames and 180 display PTS values. Edge checks cover all index widths, malformed sizes, dangling references, show-existing slots, hidden-key sync units, intra-only refresh masks, frame count limits and resolution changes.

A second Duo run used the separated reference layout plus an inserted show-existing frame. The shared writer emitted three fragments and AVPlayer decoded 111 distinct frames through 5.94 seconds, crossing both fragment boundaries with no playback error. This is local fixture playback, not evidence of general YouTube, 4K, HDR, audio synchronization or Apple TV decoder support.

For integration with the shipping URLSessionTransport, StreamingSession and loopback media server, run:

```sh
bash scripts/check_webm_http.sh
```

This opens only a local loopback listener, reconstructs all 30 fixture packets through real HTTP 206 requests, fetches a seek-selected range and checks non-2xx propagation. It uses no external service. Host sandbox settings must permit the loopback listener/client.

For the complete local HTTP range-fetch/remux/resource-serving pipeline and companion AAC playlist, run:

```sh
bash scripts/check_webm_delivery_http.sh
```

This uses two loopback listeners and the shipping transport/server/HLS helpers. It opens metadata with two HTTP ranges, serves each cue's initialization/media/partial-byte probes from one fetched range, refetches an evicted backward cue and verifies the companion AAC timeline. No external network or FFmpeg executable is required. The Apple host checks also cover exact interval boundaries, request coalescing, cache eviction/budget, capacity, deadlines, stale-generation cancellation, session-specific paths, false cue times and configuration changes.

For parser-to-playback composition checks, run:

```sh
bash scripts/check_webm_playback.sh
```

This exercises the real player-response parser, separate format catalog, unchanged MP4/SABR policy, hardware eligibility injection, level estimation/precedence, client identity, AAC index validation, preparation, precise resume range/tags, audio-only laziness, superseded failures and explicit/deinit resource release. It opens only local listeners. The checked-in source inventory is reused by host and SDK checks. Existing application composition boundaries (preferences/logging, legacy builders and caption extraction) are stubbed in `scripts/webm_playback_support.swift`; the new adapter, transport, HLS helpers, server, models and parser are shipping sources.

To verify shared SDK compatibility, install XcodeGen and XcodeBuildMCP, select installed simulator IDs, and run:

```sh
bash scripts/check_webm_platforms.sh <iOS-simulator-id> <tvOS-simulator-id>
```

This creates temporary iOS 15/tvOS 17 framework targets referencing the core and complete playback adapter directly, with Swift 5 language mode and complete concurrency checking. It does not modify either app project or require signing. The broader check also compiles existing context dictionaries and transport/server code, which currently report their pre-existing Swift 6 concurrency diagnostics; the new adapter adds no such diagnostics. Simulator compilation does not validate Apple TV hardware decoding.

## Next slice

Enable the experimental step deliberately and validate live YouTube responses, signed URL/visitor identity behavior, sustained 4K playback and perceptual A/V offset on the Duo. The original test URL is `https://www.youtube.com/watch?v=PLvSMddQtfE`. Keep normal playback-chain defaults intact while collecting actual format/source/error logs.

Actual mid-item seeking, quality/dub switching, long playback, SABR WebM delivery, HDR and Apple TV decoding still need verification. The tested replacement-item resume path does not by itself validate every player seek lifecycle. Keep this step opt-in until real-stream and device coverage supports broader activation.

References: [WebM container guidelines](https://www.webmproject.org/docs/container/), [VP9 MP4 binding](https://www.webmproject.org/vp9/mp4/), [libvpx uncompressed-header decoding](https://github.com/webmproject/libvpx/blob/main/vp9/decoder/vp9_decodeframe.c), [FFmpeg independent superframe splitter](https://github.com/FFmpeg/FFmpeg/blob/master/libavcodec/bsf/vp9_superframe_split.c).
