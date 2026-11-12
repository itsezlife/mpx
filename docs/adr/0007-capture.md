# ADR 0007: Capture: compression and round video

`mpx_capture`, a plugin, does two things in v1: it compresses a video before send against a shared preset table, and it
records round video messages. The output seam reports bytes written, the final
size and a header-rewritten signal. The host uploads the finished file. The
result lands in `http_bytes_cache` as a local resource under a local content
key so the sender's own item plays at once; after upload the host aliases the
server key to it.

**Status**: Accepted (decided with the maintainer 2026-11-10)
**Relates to**: 0001, 0002, 0008

## Context

The reference clients compress every video before send and record round video
messages. Android draws camera frames through GL into a MediaCodec encoder and
writes MP4 with its own muxer; iOS uses AVCaptureSession and
AVAssetReader/AVAssetWriter, never AVAssetExportSession for sending; desktop
uses FFmpeg with libopenh264. Both mobile clients upload while the file grows.
Our FFmpeg build is decode-only under LGPL.

## Decision

### Scope

| In v1 | Not in v1 |
| --- | --- |
| Compression before send | In-app camera for regular photo and video |
| Round video messages | Pre-send editor (trim, crop, filters) |
| Progress and cancel | Upload while recording or converting |

### Preset table (the shared contract)

| Preset | Max side | Video kbps | Audio kbps / channels |
| --- | --- | --- | --- |
| Very low | 480 | 400 | 32 / 1 |
| Low | 640 | 700 | 32 / 1 |
| Medium | 848 | 1600 | 64 / 2 |
| High | 1280 | 3000 | 64 / 2 |
| Very high | 1920 | 6600 | 64 / 2 |

H.264, 1 s GOP. The output bitrate never exceeds the source bitrate.

### Round video

| Value | Default (host-configurable) |
| --- | --- |
| Side | 384-400 px square |
| Video | ~1 Mbps, 30 fps, keyframe every second |
| Audio | AAC 64 kbps |
| Length | ≤ 60 s |
| Controls | Preview, camera switch, pause |

### Platform APIs

| Job | Android | iOS / macOS |
| --- | --- | --- |
| Compression | Media3 Transformer (H.264 + AAC, `Presentation` to preset size, encoder settings for the bitrate, transmux when nothing changes) | AVAssetReader → AVAssetWriter with explicit settings; AVAssetExportSession only for passthrough |
| Round video | CameraX preview → our GL stage → MediaCodec | AVCaptureSession → AVAssetWriter |

### Output seam

| Field | Meaning |
| --- | --- |
| Bytes written | Grows during encoding |
| Final size | Known at completion |
| Header rewritten | Set at completion when the head of the file changed |
| Progress | Encode position ÷ duration |

v1 hosts upload the finished file. The seam already allows a later uploader to
start on a growing file and re-send the head.

### Into the cache

The output registers in `http_bytes_cache` as a local resource, so the sender's
bubble plays it through the normal pipeline without a download.

| Step | Decision |
| --- | --- |
| Mint | A local key, `MediaKey.local(uuid)` from `mpx_core`, when capture or compression starts |
| After upload | The host calls `alias(local, server)` on the cache: the server key resolves to the same bytes, no copy or move |
| Bubble | Keeps playing under the local key; anyone opening the server key gets the same bytes |
| Release | The local key is released when the message is confirmed, or by normal retention |

### Licences

FFmpeg stays decode-only LGPL. No FFmpeg encoders in v1. Never libx264, libx265
(GPL) or fdk-aac (nonfree). Encoding for desktop later: libopenh264 + FFmpeg's
native AAC, which stays LGPL.

## Why

- Transformer replaces about 1.5k lines of encoder quirk handling in the
  Android reference with a maintained library, and transmuxes when no change
  is needed.
- CameraX's `Recorder` cannot set codec, container or size, so round video needs
  our own GL stage into MediaCodec, as the reference does.
- The iOS table has explicit kbps per step, so it travels across platforms;
  the Android source-bitrate ceiling keeps outputs from growing.
- Reporting bytes written now keeps live upload possible without committing v1
  to the uploader changes it needs.
- An alias binds the server identity without a key change under the playing
  bubble and without doubling the bytes.

## Rejected

| Alternative | Why not |
| --- | --- |
| CameraX `VideoCapture` / `Recorder` for round video | Codec, container and size are fixed |
| AVAssetExportSession for sending | No bitrate key; cannot hold the kbps presets |
| Raw MediaCodec + own muxer for compression | Owns every encoder quirk; only needed for live upload, which is not v1 |
| FFmpeg encoders on mobile | Battery, heat, licence surface |
| Upload while growing in v1 | Uploader must accept growing files and re-send part 0 |
| Moving or copying the file to the server key after upload | A key change under the playing bubble, or doubled bytes |

## Consequences

- `mpx_capture` carries CameraX, Media3 Transformer and AVFoundation
  capture code; hosts that skip capture never link them.
- The host owns upload and any server-tuned round video values.
- Thumbnails come from the capture stream and feed the decode tier as stills.
- `MediaKey` has a `local` variant; the bytes cache gains alias
  and release (ADR 0002, 0003).

## Open in implementation

- Whether HEVC is allowed for sends outside the preset table.
- Where server-tunable round video values come from (the host passes them;
  the shape is not fixed).
- The Android muxer choice for round video (our own growing-file writer as in
  the reference, or Media3's) and fragmented vs faststart output.
- Thumbnail API: first frame, keyframe strip.
- Size estimate before send.
- macOS camera permissions and device selection.

## Provenance

Planning tickets `06`, `12`, `23` (local key and alias); research
`06-recording-transcoding` (reference encoders, iOS preset
table, Android bitrate rules, platform options, FFmpeg licence by encoder).

## Related

ADR 0002 (local resource), 0008 (licences and binaries).
