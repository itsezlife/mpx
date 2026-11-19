# ADR 0007: Capture: compression and round video

`mpx_capture`, a plugin, does two things in v1: it compresses a video before send against a shared preset table, and it
records round video messages. The output seam reports bytes written, the final
size and a header-rewritten signal. The host uploads the finished file. The
result lands in `http_bytes_cache` as a local resource under a local content
key so the sender's own item plays at once; after upload the host aliases the
server key to it.

**Status**: Accepted (decided with the maintainer 2026-11-10; amended by ADR
0011 on 2026-11-20: still preparation, the 432 preset, the camera session)
**Relates to**: 0001, 0002, 0008, 0011

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
| Compression before send, and still preparation (ADR 0011) | In-app camera for regular photo and video (moved into v1 by ADR 0011) |
| Round video messages | Pre-send editor (trim, crop, filters) |
| Progress and cancel | Upload while recording or converting |

### Preset table (the shared contract)

| Preset | Max side | Video kbps | Audio kbps / channels |
| --- | --- | --- | --- |
| 432 (ADR 0011; Android policy only) | 432 | ≤ 750 | 32 / 1 |
| Very low | 480 | 400 | 32 / 1 |
| Low | 640 | 700 | 32 / 1 |
| Medium | 848 | 1600 | 64 / 2 |
| High | 1280 | 3000 | 64 / 2 |
| Very high | 1920 | 6600 | 64 / 2 |

H.264, 1 s GOP. The output bitrate never exceeds the source bitrate.

Which steps a platform offers, and the stills' side limits, JPEG qualities
and thumbnails, are the preparation policies of ADR 0011
(`PreparationPolicy.$Android` / `$IOS` / `$Desktop` / `$Web`).

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
- Camera and microphone permissions live here, with one exception (ADR
  0011): `mpx_library`'s system camera intake needs the iOS camera usage
  string, with no session.
- The host owns upload and any server-tuned round video values.
- Thumbnails come from the capture stream and feed the decode tier as stills.
- `MediaKey` has a `local` variant; the bytes cache gains alias
  and release (ADR 0002, 0003).

## Settled in implementation

- The plan (output size, bitrate, passthrough) is computed once in Dart from
  a native probe, so every platform applies one rule: the long side scaled
  down to the step, sides rounded to even, bitrate the lower of the step's
  and the source's, and an H.264 source with neither size nor bitrate to
  change is remuxed. kbps are 1000 bits. Sends are H.264 only; no HEVC in v1.
- Apple writers set `shouldOptimizeForNetworkUse` (index at the front);
  Android compression uses Media3's default muxer, round video the
  platform `MediaMuxer`, both non-fragmented. Every v1 writer changes the
  head of the file at the end, so `headerRewritten` is set on every output;
  the field stays for a later fragmented or growing-file writer.
- Round video values arrive as a `RoundVideoConfig` the host builds (from
  its server or the defaults).
- macOS: the first camera counts as front, a second as back; permissions
  are the camera and audio-input sandbox entitlements plus the usage strings.
- Capture output moves into the store under `MediaKey.local(uuid).encoded`,
  the fetch adapter's content key, in pieces as a complete ranged resource
  where the store keeps ranges. `mpx_capture` does not depend on `mpx`; the
  host names the server key through the adapter's `cacheKeyOf`.

## Open in implementation

- Thumbnail API: first frame, keyframe strip.
- Size estimate before send.

## Provenance

Planning tickets `06`, `12`, `23` (local key and alias); research
`06-recording-transcoding` (reference encoders, iOS preset
table, Android bitrate rules, platform options, FFmpeg licence by encoder).

## Related

ADR 0002 (local resource), 0008 (licences and binaries).
