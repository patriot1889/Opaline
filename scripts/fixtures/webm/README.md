# VP9 WebM fixture

`vp9-sdr.webm` is a locally generated three-second, 32×32, 10 fps SDR VP9 Profile 0 test pattern. It contains front-loaded Cues and multiple keyframe-aligned Clusters. No third-party media is included.

Regenerate with FFmpeg and ffprobe:

```sh
ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc2=size=32x32:rate=10 \
  -t 3 -an -c:v libvpx-vp9 -deadline good -cpu-used 4 -b:v 16k -g 10 \
  -lag-in-frames 25 -auto-alt-ref 1 -pix_fmt yuv420p -dash 1 -cues_to_front 1 vp9-sdr.webm
ffprobe -v error -select_streams v:0 -show_packets \
  -show_entries packet=pts_time,duration_time,flags,size,data_hash \
  -show_data_hash sha256 -of json vp9-sdr.webm > vp9-sdr-packets.json
```

Encoded bytes may change between encoder versions. Regenerate the WebM and golden packet description together, review their metadata, then run `bash scripts/check_webm.sh` from the repository root.

`vp9-sdr-playback.webm` is a separate 640×360, three-second, 10 fps SDR profile-0 fixture for hardware playback. It has 30 visible packets, keyframes every second and no alternate-reference lag. The 32×32 parser fixture fails hardware playback on the Duo despite valid packet readback; use the larger fixture for playback checks.

```sh
ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc2=size=640x360:rate=10 \
  -t 3 -an -c:v libvpx-vp9 -deadline good -cpu-used 4 -b:v 300k -g 10 \
  -lag-in-frames 0 -pix_fmt yuv420p -dash 1 -cues_to_front 1 vp9-sdr-playback.webm
```
