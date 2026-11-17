# ADR 0004: The player

`mpx_player` plays the item that has sound: the viewer's video, the focused
reel, a round video with sound. Players live in a pool keyed by `MediaKey`.
Surfaces lease a player and attach views, so a hand-off keeps position, buffer
and sound. One audio owner per app allows at most one audible player. The
native backends are Media3 ExoPlayer on Android and AVPlayer on Apple, each
rendering into its own texture and reading bytes through the bytes cache's
native reader. Apple v1 plays progressive MP4 only. v1 runs from Android API
24, iOS 15 and macOS 12.

**Status**: Accepted (decided with the maintainer 2026-11-10)
**Relates to**: 0001, 0002, 0003, 0005, 0006

## Context

Both mobile reference clients run two tiers: a software decoder for many silent
loops, and a hardware player for the one item with sound. The silent tier
exists (`mpx_video_decoder`, the CPU texture pool). The hardware tier does not.
The Flutter engine accepts an Android `SurfaceProducer` (zero-copy through a
PRIVATE ImageReader on API 29+) and an Apple `FlutterTexture` pulling
`CVPixelBuffer`s, where NV12 is always converted as BT.601 8-bit. A BufferQueue
has one producer at a time, so a player cannot write into the CPU pool's
surfaces.

## Decision

### Ownership and API

| Area | Decision |
| --- | --- |
| Pool | `PlayerPool` keyed by `MediaKey`. Players are leased like assets |
| Lease | `PlayerLease` from the pool by key. Commands on the lease: play, pause, seek, speed, loop, volume |
| Surfaces | Bubble, feed cell, viewer and PiP attach views to one player. Several may attach at once |
| State | One immutable `PlayerState` through Flutter's `ValueListenable`: phase, play wish, buffered ranges, video size and quarter turns, texture, settings, error |
| Playhead | Read per frame, never pushed as events |
| Budget | `PlayerBudget(active, prepared)`; past the capacity the coldest non-playing engine is released (unleased, then unshown, then least recently used), keeping its position. Feed and viewer policies fill it; device class and decoder-instance caps bound it |
| Core | Follows the core's clock pause layers and visibility; one texture per player, outside the CPU texture pool and its budget |
| Bytes | Through the ranged resource of `http_bytes_cache` (ADR 0002). Edge `mpx_player -> http_bytes_cache`, Dart and native code alike; the player owns no range protocol of its own |

### Sound

| Area | Decision |
| --- | --- |
| Audio owner | One per app, inside `mpx_player`. A new audible player silences the previous |
| System focus | Calls, other apps, headphones handled by the audio owner |
| Implemented as | The pool itself is the owner (`PlayerPool.soundOwner`); audible = playing, volume above 0, not ended; a new owner pauses the previous; muted players play beside it. Platform focus through `PlayerBackend.audioFocus` (`AudioFocus`: `request`, `abandon`, `changes` of `gained` / `lost` / `interrupted` / `outputRemoved`). An interruption (a duck request included: video is often speech) pauses and resumes on `gained`; `lost` and `outputRemoved` pause for good. Leaving the screen: `PlayerPool.onSoundOwnerLeftScreen(key)`, fired when the owner's last view goes and none takes it in the same turn; pauses when the host passes none |
| Leaving the screen | The host decides: pause or PiP |

### Hand-off with the software path

Bubble (silent loop, software decoder) to fullscreen: the player starts at the
bubble's position, and the bubble's frame shows until the player's first frame.
On close the bubble continues from the player's position.

### Backends

| Need | Android | iOS / macOS |
| --- | --- | --- |
| Engine | Media3 ExoPlayer | AVPlayer + `AVPlayerItemVideoOutput` |
| Texture | Own `SurfaceProducer` per player; handle surface cleanup and re-attach | BGRA with BT.709 colour properties on the output settings into an IOSurface `FlutterTexture`; pulled on a display link. Never NV12 |
| Rotation | `Format.rotationDegrees`, applied in Dart | `preferredTransform` baked in |
| HDR | `KEY_COLOR_TRANSFER_REQUEST` to SDR on API 31+; else SDR-clipped | Tone-mapped to BT.709 SDR by the output settings |
| Bytes | Custom `DataSource` over `http_bytes_cache`'s native reader | `AVAssetResourceLoaderDelegate` on a custom scheme, `isByteRangeAccessSupported`, over the same native reader (MP4 in v1) |
| Feeds | `DefaultPreloadManager`, 1 active + up to 2 prepared, capped by `getMaxSupportedInstances` | `preferredForwardBufferDuration` |
| PiP | Activity PiP; the texture keeps playing | Hidden `AVPlayerLayer` on the same player for `AVPictureInPictureController` |
| Background audio | `MediaSessionService` | `.playback` session, audio background mode, hidden layer |
| Robustness | Hardware decoder probe before choosing a quality; on an AV1 decoder failure, persist it, drop AV1 qualities, re-prepare | None extra |
| Minimum | API 24. API 24-28: the engine's copying texture path (slower, functional); zero-copy from API 29; HDR tone-mapping from API 31 | iOS 15, macOS 12; everything above is available there |

### Apple HLS

A probe on macOS 26.6.1 and the iOS 26.4.1 simulator showed that AVPlayer sends
HLS playlists, init sections and segments to the resource loader, but fails with
CoreMedia `-12881` on any segment bytes the delegate serves itself. Playlists
through the loader work; segments work only as `http(s)` (a 302 redirect to
`https` plays, a redirect to `file://` loops). Progressive MP4 through the
loader plays end to end with ranged requests. Apple v1 is therefore progressive
MP4 only. HLS later goes through a loopback HTTP proxy that serves segments from
the bytes cache, with playlists still through the loader.

## Why

- ExoPlayer and AVPlayer bring A/V sync, seek, speed, loop, PiP and HDR
  handling with the least native code. The Android reference stays on ExoPlayer.
- BGRA with BT.709 sidesteps the engine's BT.601-only NV12 path and does the
  colour conversion on the GPU inside AVFoundation.
- A pool keyed by content means the bubble, feed and viewer never hold two
  decoders for one file; hand-offs do not restart.
- One audio owner matches the reference's single sound-carrying player.
- Reading through the cache's own native reader keeps the range protocol in
  one package and the hot read path native.
- The minimums match Flutter and the chat app; API 24-28 devices still play,
  only without zero-copy.

## Rejected

| Alternative | Why not |
| --- | --- |
| Raw MediaCodec | Rebuilds extraction, audio clock, seek, ABR and buffering that ExoPlayer has |
| libmpv / media_kit | Safe hwdec copies back to RAM on Android; GLES on Apple |
| better_player | Deprecated texture API; a feature checklist only |
| Platform views (`SurfaceView`, `AVPlayerLayer`) | Hybrid composition cost; textures suffice |
| HW players for every inline clip | Decoder-instance limits and black frames while scrolling |
| Apple HLS through the resource loader alone | Fails with `-12881` on segments |
| FFmpeg + VideoToolbox on Apple now | Kept as the fallback only if WebM/VP9 or software AV1 must play with sound |
| Reaching the ranged store through the core's fetch seam or a host-wired contract | Adds a hop or host wiring on the hot read path |
| Android API 29 as the minimum | Drops devices Flutter and the chat app support |

## Consequences

- `mpx_player`'s native code links `http_bytes_cache`'s native reader and opens it by
  key (ADR 0002).
- Android keeps two texture paths: copying on API 24-28, zero-copy from 29.
- The player has its own texture memory budget beside the CPU pool (7
  ImageReader buffers per producer on Android; a few BGRA buffers on Apple).
- Apple hosts serving HLS content must offer an MP4 alternative in v1.

## Settled in implementation

Tickets 23-26, 28, 29 (2026-11-13).

- **Channel**: Pigeon (`pigeons/player_messages.dart`): ten typed commands
  down, whole state snapshots up (on each change and about once a second
  while playing), audio focus and picture-in-picture events up. Chosen over
  hand-written method channels because three languages share the shapes and
  the generator keeps them in step. The playhead is extrapolated in Dart
  between snapshots; a seek reads at its target until a snapshot echoes its
  id.
- **Backend**: `NativePlayerBackend` in `package:mpx_player/native.dart`
  (imports `dart:ffi` through the reader). The host maps a key to
  `PlayerSource`s (a `RangedRequest`, container MIME, codec), best first;
  the engine publishes the chosen one to `NativeRangedReaders` and hands
  the platform player its cache key.
- **Reader link**: Swift and the Android JNI shim mirror the `hbc_api`
  layout and refuse another version (a published plugin cannot include a
  sibling package's header).
- **Apple frames**: a display link (macOS 14+ the screen's, earlier
  `CVDisplayLink`) plus a 15 Hz backup timer whenever the link is silent
  (a hidden or never-foregrounded window), so the first frame is still
  reported. Rotation is baked by a video composition (`quarterTurns` 0).
- **Android**: Media3 1.11.1, one ExoPlayer per player on its own
  `SurfaceProducer`; `quarterTurns` from `Format.rotationDegrees` only when
  the producer does not apply the transform (the zero-copy path). HDR asks
  for SDR tone-mapping (`KEY_COLOR_TRANSFER_REQUEST`) on API 31+. A seek
  cancels the reads blocked for that player. No `DefaultPreloadManager`:
  prepared engines under `PlayerBudget` plus the feed's byte preloads cover
  the warm neighbours without its play-on-its-own-builder rule. Playback
  starts on 100 ms of buffered media (1000 ms after a stall) instead of
  Media3's 1000 / 2000: every read is from the bytes cache's sparse file,
  which fetches ahead on its own, so the defaults only delayed the start.
  Amended 2026-11-17: a player that has not played yet buffers at most
  `PreparedBuffer` ahead (2 s and 2 MiB by default; a capped `LoadControl`
  on Android, `preferredForwardBufferDuration` on Apple, which has no byte
  cap), lifted at its first play, so prepared neighbours fetch little more
  than their first frame and a short start.
- **Texture budget**: one texture per engine, so `PlayerBudget.capacity`
  bounds the player's textures; no separate byte budget.
- **Audio focus**: Android `AudioFocusRequest` and the noisy-output
  broadcast; iOS the `.playback` session's interruption and route-change
  notifications (an interruption that ends without "should resume" is
  `lost`); macOS none.
- **Prepared gate**: `PlayerDevice.budget`: two prepared players on a
  high-class device (media performance class S+, or 8 cores with a 160 MB
  memory class, or 6 GiB) with at least 8 HEVC decoder instances; none
  otherwise. Apple reports no instance counts and gates on class alone.
- **Decoder failure**: Android persists the failed video codec; the engine
  re-prepares the next source from the same position and later engines
  skip that codec.
- **HLS on Android** (ticket 52): `PlayerSource.hls`; Media3's
  `HlsMediaSource` opens the playlist URL and asks Dart for each part over
  Pigeon (`openStreamPart`), the loader thread waiting for the answer
  (interrupted when the load is cancelled). Dart keys each part by its URL
  under the stream's key (`BytesCacheKey.within`). Playlists, and any part
  other than media and init sections (keys), are whole resources resolved
  through the cache's ladder with HTTP revalidation (stale on a network
  failure) and handed over as bytes; segments and init sections are ranged
  resources published to the native reader and withdrawn when the player
  closes them or the engine goes. Apple's probe lists progressive
  containers only, so an HLS source is skipped for the next. DASH is not
  wired (another extension and no data type per request to tell manifest
  from segment).
- **Picture in picture**: `PictureInPicture` on `PlayerBackend`; the pool
  counts the window as a view. Apple: a hidden one-point `AVPlayerLayer` on
  the same player in the key window. Android: activity picture in picture
  (`stopPictureInPicture` cannot close the system window there).
- **Background**: without `backgroundAudio` players pause when the app is
  hidden (not while in picture in picture). With it: Android's
  `MpxPlaybackService` (a `MediaSessionService` the host declares); Apple
  needs nothing native since frames go to a video output, not a layer.

## Open in implementation

- iOS background-audio rule (visible layer pauses video): unverified, verify
  on device.
- Concurrent decoder limits on Apple: undocumented, measure on device.
- ABR on Android HLS: segment reads are not network transfers to Media3's
  bandwidth meter, so variant choice runs on its initial estimate; it comes
  back with the feed's resolution and quality knobs.
- A pause from outside the app (a media notification, the picture-in-picture
  window's own button) is not mirrored into the play wish yet; the next
  snapshot shows the playhead stopped.
- The loopback proxy for Apple HLS: design and timing.
- Linux desktop and a synchronized stream group (a later effort, kept
  possible): several streams (8–25) on one external master clock with
  per-stream offsets and gaps in time, a Linux backend behind
  `PlayerBackend` (FFmpeg with hardware decode, or libmpv), Linux textures
  through the embedder's texture registrar, memory under a fixed budget.
  Until then new code keeps to: engines accept an injected clock rather
  than owning time; the software path reads through the bytes cache's
  native ranged reader in portable C; no media file is loaded whole into
  memory; HLS parsing sits above the bytes cache, not only inside a platform
  player; the frame-texture API stays platform-neutral.

## Provenance

Planning tickets `02`, `03`, `09`, `16`, `17` (bytes edge), `26`
(minimum versions); research
`02-hw-player-backends` (engine source, video_player, media_kit,
reference players, limits), `03-streaming-cache.md`. Probe source and logs are
in the session scratchpad named in ticket 16.

## Related

ADR 0002 (ranged reads), 0005 (feed budget), 0006 (viewer playback and PiP).
