# Spec: mpx, the portable media monorepo

Status: accepted, ready to cut into tickets. Decided with the maintainer on
2026-11-10 through the planning wayfinder map. Each decision traces to a
planning ticket, and the facts and constants to planning research notes. The ADRs
in `adr/` hold the reasoning. This file is the whole system on one page.

The planning scratch (map, planning tickets, research notes) and the
implementation issue list stay in chat_scroll_view's local scratch area; they
are not part of this repository. "Planning ticket NN" and "research NN-name"
below name those notes as plain text.

## 1. What mpx is

mpx is a separate pub workspace of Flutter and Dart packages that any app can
depend on for media. It covers:

- fetching and caching bytes, whole bodies and byte ranges, on one disk store;
- decoding stills, Lottie and short video into textures (the media core and the
  decoders that live in chat_scroll_view today);
- a hardware video player with sound, seek and a streaming cache;
- feed and reels playback policies and widgets;
- a fullscreen viewer that follows each platform's reference client;
- compression before send and round video recording.

chat_scroll_view becomes one consumer among others. The chat keeps its own
domain (rich text, packs, the glyph atlas, embeds, presets).

### Goals

1. One bytes cache for every media kind, with one disk budget and named quotas.
2. The one hardware player per audible item, shared by every surface that shows
   that item, so a hand-off never restarts playback.
3. Silent inline loops stay on the software decoders and the CPU texture pool,
   as both mobile reference clients do.
4. Viewer, feed widgets and capture are optional. A host that only shows
   images takes `mpx_core`, `http_bytes_cache` and `mpx` (which joins them).
5. A package boundary stands only where a host would otherwise pay for what it
   does not use: heavy native code, permissions, or a standalone pure-Dart
   library. Eight packages in all (ADR 0001).
6. Every package is publishable on pub.dev under the `mpx_` prefix (the bytes
   cache as `http_bytes_cache`, the umbrella as `mpx`), with prebuilt native
   binaries downloaded and verified by build hooks.

### Non-goals (out of scope for v1)

- Windows, Linux and web as targets. Code that runs there today moves as is;
  v1 makes no promise for them, and a later effort maps the same layers there.
- DRM and protected content.
- Explicit offline downloads (Apple `AVAssetDownloadURLSession`, Media3
  download service).
- HLS on Apple. Apple v1 plays progressive MP4 only; HLS comes later through a
  loopback HTTP proxy for segments (ADR 0004).
- The in-app camera for regular photo and video, and the pre-send editor.
- Upload while recording or converting. The capture output seam keeps it
  possible; v1 uploads the finished file.
- FFmpeg encoders. The FFmpeg build stays decode-only under LGPL.
- A separate OS window for the macOS viewer and a frameless PiP window. Both
  need Flutter multi-window; v1 is an in-app overlay (ADR 0006).
- Legal review of LGPL FFmpeg in App Store apps. That is the maintainer's
  action before the native video packages publish, not a design decision.
- Quality-of-experience metrics, diagnostics dashboards, accessibility and
  captions beyond what the viewer reference draws.

## 2. Package set

Prefix `mpx_` on every package except the bytes cache, `http_bytes_cache`,
which caches any HTTP bytes and stands on its own. The umbrella `mpx` is the
host's composition root, with no re-exports (ADR 0001). Arrows point at the
dependency.

```
http_bytes_cache              Dart + native reader: whole + ranged resources, one disk store,
                              HTTP middlewares
mpx_core                      plugin: MediaKey / MediaDescriptor, asset cache, pipeline, clock,
                              pause layers, budgets, visibility, texture hosts, image decoder
mpx_lottie               ---> mpx_core                    (+ build hook: Rust over tlottie)
mpx_video_decoder        ---> mpx_core                    (+ build hook: FFmpeg + libvpx, decode-only)
mpx_svg                  ---> mpx_core                    (SVG decoder: sanitizer, limits, worker compile)
mpx_player               ---> mpx_core, http_bytes_cache  (plugin: pool, Media3 / AVPlayer, feed policies)
mpx_library              ---> mpx_core                    (plugin: media library, file intake, library fetcher)
mpx_ui                   ---> mpx_player, mpx_core,       (viewer, feed list and pager widgets,
                              mpx_library                 library grid)
mpx_capture              ---> mpx_core, http_bytes_cache  (plugin: CameraX, Transformer, MediaCodec / AVFoundation)
mpx                      ---> mpx_core, http_bytes_cache  (plugin: composition root, fetch adapter,
                                                           device signals)
```

`mpx_core` and `http_bytes_cache` do not depend on each other; `mpx` joins
them. `mpx` depends on no decoder, player, UI, library or capture package;
the host passes decoders into the stack and wires the optional packages.
`mpx_ui` takes no edge to `mpx_capture`: the library grid leaves a camera
slot the host fills (ADR 0011).

Stays in chat_scroll_view: `content_model` (rich text, collections, packs,
library, `ContentKey` and `ContentDescriptor`; pure Dart, no mpx dependency),
the `ContentKey` to `MediaKey` mapping, the glyph atlas (its own package in the
chat repo), inline and content embeds, emoji, sticker and panel presets and
budgets, `chrome_foundation`.

## 3. Packages, responsibilities and public seams

Type names already in code keep their names. Names marked *(working)* are
proposals for the first ticket of that package to confirm.

### http_bytes_cache

The renamed image_bytes_cache. Pure Dart core plus a native reader.

- Whole resources: the resolve ladder (fresh, conditional GET, unconditional,
  stale only on network error), in-flight coalescing with per-caller cancel.
- Ranged resources, owned end to end: range requests, writes into one sparse
  file per resource, a range-set index row with a strong validator, its own
  quota, and the "range landed" signal. `Range` / `If-Range`, `206`; a `200`
  answer to a ranged request drops the stale spans.
- Native reader by key: native players open it; it reads the sparse file
  directly, blocks on a missing range, asks Dart to fetch it, and wakes when
  Dart signals over FFI that the range landed. C symbols `http_bytes_cache_*`
  (short `hbc_*`).
- One disk store, one index, one eviction by last use, named quotas (images,
  video ranges, Lottie frames, glyphs). Lottie frame caches and glyph pages
  keep their own files and formats; their folders register as named quotas,
  and the store asks their owner to evict through a callback per quota. It
  never touches files it does not own.
- Request priorities: visible > preload > background, changeable while queued
  or in flight; the 6-slot queue serves by priority, then arrival.
- Stale-while-revalidate as a per-request policy: serve stale bytes at once and
  revalidate in the background through ETag / Last-Modified. Media defaults to
  no revalidation (immutable); avatars and similar opt in.
- Aliases: `alias(local, server)` makes a server key resolve to a local
  resource's bytes with no copy or move; `release(local)` drops the local key.
- HTTP client with middlewares: timeout, retry, bearer, conditional (ETag),
  logger; streaming bodies added.
- Seams: *(working)* `BytesResolver`, `BytesStore` (index + blob ports),
  `RangedResource`, `HttpBytesClient`, `HttpBytesMiddleware`, `CacheKey`
  (host-supplied identity override, mandatory for media), `BytesRetention`
  with named quotas, `FileLease` (a path handed out and pinned against eviction),
  `RequestPriority`, `RevalidationPolicy`.
- Named quotas include `BytesQuota.previews` (4 MiB) for derived previews
  beside `BytesQuota.standard` (ADR 0010).
- Gaps to close before it serves the core: progress fan-out with late-join
  replay and a 0 report, a sync peek, file handout with eviction pinning,
  last-use expiry, the shared disk store. ADR 0002.

### mpx_core

The product-neutral part of `catalog_assets`, with the frame texture plugin
and the engine image decoder folded in. No networking.

- Identity: `MediaKey` (stable identity of a piece of media, never a URL) and
  `MediaDescriptor` (kind, size, dimensions, duration) *(working names)*. A
  `MediaKey.local(uuid)` variant names a locally produced file before the
  server knows it. Hosts with their own identity (the chat's `ContentKey`) map
  onto it.
- Asset cache, fetch + decode pipeline, playback clock and pause layers,
  budgets, visibility, texture seam, placeholders, `AssetView`.
- Texture hosts implementing `FrameTextureHost` (Android `SurfaceProducer`,
  Apple `FlutterTexture` over a `CVPixelBuffer` ring), channel
  `dev.mpx.frame_texture`.
- The engine image codecs as a `Decoder`.

- Existing seams: `ContentFetcher` (`fetch(FetchRequest) -> FetchedContent`,
  sync `needsDownload`), `FetchedBytes` / `FetchedFile`, `CancellationToken`,
  `Decoder`, `AssetPipeline`, `AssetBinding`, `PlaybackPauseLayer`,
  `FrameTextureHost`, `AssetCacheProvider`, `AssetView`.
- Additions from the feed decision: a visible fraction on bindings, staged
  preload requests with priority and cancel, network and power inputs on the
  pause layers. ADR 0003.
- Loading stages (ADR 0010):
  - preview: `MediaPreview` (`raster` / `outline`) on `MediaDescriptor`,
    with `streamable`; `AssetStage.preview` between `none` and
    `placeholder`; `PreviewStore` (derived previews), `PreviewBlur`,
    `ThumbnailBlurRule`; `ClearPlaceholder` as the scope default;
  - transfer: `AssetTransfer` (`none`, `waiting`, `receiving`,
    `awaitingUser`, `failed`), `AssetBinding.descriptor`, `download()`,
    `cancelDownload()`, `AssetCacheScope.know`;
  - auto-download: `AutoDownloadPolicy` (`now` / `prefix` / `manual`,
    default `always`) with an opaque `AutoDownloadContext` per attach;
  - status control and badge: `MediaStatusControl` over a `MediaStatus`,
    `MediaBadge`, styled by `MediaLoadingStyle` and
    `MediaLoadingStyleScope`;
  - decoders: `DecodeFailure.unsupported` and
    `DecoderRegistry.registerFallback`.

### mpx_lottie, mpx_video_decoder

Each is a decoder with its native library in one package, built through a
build hook. They keep their shape and implement the core's `Decoder`. Native
names: `mpx_lottie_*` / `libmpx_lottie`, `mpx_video_*` / `libmpx_video`, the
env var `MPX_VIDEO_FFMPEG_DIR`. ADR 0003.

### mpx_svg

The decoder of `MediaKind.vectorImage`: SVG sanitized and compiled under a
host policy (`SvgLimits`) on a worker isolate, then drawn into an image at
the spec, so the content views draw it like any still. ADR 0003.

### mpx_player

One player model for the audible item: viewer, focused reel, a round video with
sound.

- `PlayerPool` keyed by `MediaKey`; a surface takes a `PlayerLease` and
  attaches a view. Several surfaces attach to one player; position, buffer and
  sound carry across a hand-off. The pool's prepared/active budget comes from a
  policy.
- Commands on the lease: play, pause, seek, speed, loop, volume.
- State: one immutable value through a `ValueListenable` (package:listen) with
  phase, buffered ranges, video size and error. The playhead is read per frame.
- One audio owner app-wide: at most one audible player, system audio focus
  handled inside; the host decides pause or PiP when the audible player leaves
  the screen.
- Backends: Android Media3 ExoPlayer into its own `SurfaceProducer`; Apple
  AVPlayer + `AVPlayerItemVideoOutput` (BGRA, BT.709) into an IOSurface
  texture, hidden `AVPlayerLayer` for PiP. Bytes come from `http_bytes_cache`'s
  native reader inside a custom `DataSource` and an
  `AVAssetResourceLoaderDelegate` (MP4 on Apple v1).
- Android API 24-28 uses the engine's copying texture path; zero-copy from API
  29; HDR tone-mapping from API 31.
- Seams: `PlayerPool`, `PlayerLease`, `PlayerValue` *(working)*,
  `PlayerView` *(working)*, `AudioOwner` *(working)*, `PlayerBudgetPolicy`
  *(working)*. ADR 0004.
- Feed policies: two modes on one knob set, `list` (every visible clip plays
  muted) and `pager` (one active item with sound, ±1 warm, at most 2 prepared
  players). The 25 knobs of research `05-feed-policies` §7 are the seam,
  each with the reference default. Preload by distance and direction.
  Platform signals reach it through one host seam. Seams: `FeedPolicy`
  *(working)*, `FeedMode`, `FeedSignals` *(working)*. ADR 0005.

### mpx_ui

The optional UI over the player.

- Feed widgets: a list and a pager driven by the player's feed policy.
  ADR 0005.
- Fullscreen viewer: one viewer structure, three pure policies: `ViewerPolicy.$Android`, `$IOS`,
`$Desktop`. Each platform follows its own reference client; a host may pick
any. On macOS the viewer is an in-app overlay over the whole app window;
"fullscreen" puts the app window into fullscreen and PiP uses the system
`AVPictureInPictureController`. Host seams: `GallerySource` (indexed, loads
both ways, total count) and `OriginBridge` (rect, corner radius, clip, current
frame per index). The package draws bars, menu and caption; the host supplies
actions (save and share among them, on every platform, handed the cached file
path and the current frame) and caption builders; speed, quality, PiP and
rotation are built in. Tokens come from the host. ADR 0006.
- Library grid (ADR 0011): `LibraryGrid` over a `mpx_library` album with
  `LibraryGridPolicy.$Android` / `$IOS`: fixed square cells through the
  asset cache (a thumbnail key per cell pixel size), pages loaded around the
  viewport with one screen of prefetch, a **picker selection**
  (`PickerSelection`, `OrderedPickerSelection` with a cap, a gate and single
  select) with numbered checks, swipe select per policy, refusals to the
  host, the host's **camera slot** with its pause signals, change events
  that keep the selection. `LibraryPicker` adds the album switcher, every
  library access state with its banners, and the **picker-mode viewer**
  (`PickerViewer`, the viewer under the picker's check, counter and host
  bottom slot).

### mpx_library

The device media library and the file intake, a plugin that declares no
permission (the host declares them, and opts into the Apple code with
`MPX_LIBRARY_PHOTOS` / `MPX_LIBRARY_CAMERA`). `MediaLibrary`: `access`
(a listenable **library access**), `requestAccess`, `manageSelected`,
`openSettings`, `albums`, `page(album, offset, limit)`, `changes`,
`thumbnail`, `original` (a file lease). A library asset is
`MediaKey.external('device-library:<id>')`, each thumbnail size its own
key; `LibraryFetcher` serves them to the pipeline ahead of the host's
network fetcher. `FileIntake`: `pickFiles(filter, multiple)` and
`captureWithSystemCamera(kind)`, answering intake files. Android
(MediaStore) and iOS (PhotoKit) adapters; the intake also on macOS and
web. ADR 0011.

### mpx_capture

Compression before send against a shared preset table (with the 432 px
step the Android policy offers), media preparation, and round video
messages. **Media preparation** (`MediaPreparer.prepare(input, intent,
policy)`, two items at a time, off the UI isolate) scales and encodes
stills, compresses or passes videos through, and reads thumbnails and
facts, by a **preparation policy** (`PreparationPolicy.$Android` /
`$IOS` / `$Desktop` / `$Web`, ADR 0011). A **camera session**
(`CameraSessions.open`, one per process) gives a preview texture, photos,
videos, a camera switch, a flash, pause and a frame-rate cap; the minimal
**capture surface** (`CameraCaptureSurface`) takes the running session
over from a small preview and gives it back without a restart. Output seam reports bytes written, final size and a header-rewritten
signal; the result lands in `http_bytes_cache` as a local resource under a
`MediaKey.local` key, and the host aliases the server key to it after upload.
Camera and microphone permissions live here; `mpx_library`'s system camera
intake is the one exception (the iOS camera usage string). Seams:
`CompressionPreset`, `RoundVideoConfig`, `Transcoder`, `RoundVideoRecorder`,
`CaptureProgress`, `PreparationCodec`, `MediaPreparer`,
`PreparationPolicy`, `CameraSession`, `CameraSessions`. ADR 0007, 0011.

### mpx

The composition root, a plugin.

- `MpxStack.create(...)` wires the bytes cache and the core with
  defaults, takes the decoders the host passes in, and returns the assembled
  stack. It depends on no decoder, player, UI or capture package.
- The fetch adapter `BytesCacheFetcher`: a `ContentFetcher` over `http_bytes_cache` (media key to
  cache key, cancel tokens, transient and permanent error classes, progress).
  Hosts with their own fetcher skip `mpx`. ADR 0002.
- Device signals (Android, iOS, macOS): network class, power-saving mode and
  thermal status as `ValueListenable`s. The stack feeds them into the core's
  pause layers (`lowPower`); the host passes them to the feed's signal seam.
  ADR 0005.
- Registers named quotas for folders the host hands it (Lottie frames, glyph
  pages) with their eviction callbacks. ADR 0002.
- Loading defaults (ADR 0010): `NetworkAutoDownloadPolicy` (device signals'
  network class and per-kind size limits, per platform preset and per host
  context tag) and `BytesCachePreviewStore` (derived previews under the
  `previews` quota); `MpxStack.create` uses both by default.
- It re-exports nothing; hosts import the packages whose types they use. It
  carries the README with the diagram of the whole set, and the example app.
  ADR 0001.

### Glossary (library and picking, ADR 0011)

| Term | Meaning |
| --- | --- |
| Media library | The device's photo and video library behind `MediaLibrary` |
| Library access | How far the user lets the host read it: not determined, denied, restricted, limited, partial, full |
| Manage selected | Letting the user change the items a limited or partial access covers |
| Library album | One album of the library; the all-media album comes first |
| Library asset | One photo or video of the library, keyed by its platform id |
| Library page | A window of an album's assets by offset |
| File intake | Taking files in from outside the library: system dialog, system camera, drop, paste |
| Intake file | A file the intake took in: a path or a blob handle, with name, size, MIME, modified time |
| Media preparation | Making a picked item ready to upload: stills scaled and encoded, videos compressed, thumbnails and metadata |
| Preparation policy | The per-platform values of media preparation |
| Camera session | A live camera with a preview texture, photo and video capture |
| Capture surface | The minimal full-screen camera over a camera session |
| Library grid | The grid of a library album's thumbnails with selection |
| Picker selection | The ordered selection seam the grid and the picker-mode viewer share |
| Camera slot | The grid cell the host fills with a camera preview |
| Picker-mode viewer | The viewer composed for picking, with a check, a counter and a host slot |

## 4. Cross-cutting rules

- No package re-exports another package's API, `mpx` included. Hosts import
  what they use.
- Fakes and contract suites are exported only from each package's
  `testing.dart`; `flutter_test` stays a regular dependency for it. Production
  code never downcasts to a fake or a concrete cache.
- Native code lives in the package whose Dart calls it. Build hooks:
  `mpx_lottie`, `mpx_video_decoder`. Plugins (`mpx_core`, `mpx_player`,
  `mpx_library`, `mpx_capture`, `mpx`) are single, not federated, and support Swift Package
  Manager.
- A new package needs a reason from ADR 0001's list (heavy native code,
  permissions, standalone pure Dart, large optional UI, wiring); anything else
  is a folder.
- Native names (C symbols, libraries, asset ids, channel ids, env vars) start
  with the `mpx` prefix and the owning component: `mpx_lottie_*`, `dev.mpx.frame_texture`,
  `MPX_VIDEO_FFMPEG_DIR`, `http_bytes_cache_*` / `hbc_*`. No `chat_` remains.
- `mpx_ui`, `mpx_library` and `mpx_capture` are optional. Nothing below them
  imports them.
- No reference-client citations (file names, line numbers, client names) in
  code, tests, READMEs or CHANGELOGs. Provenance lives in ADRs and planning
  scratch only.
- Docs follow the agnostic-documentation rules: contracts and roles, no product
  screens, no history.
- A leaf that fails keeps the best picture stage it reached (preview,
  thumbnail or first frame); there is no failed picture. A surface that shows
  a status control turns it back to download, which is the retry. A leaf
  without a control (glyphs, panel cells, embeds in text) shows nothing more
  (ADR 0010).
- Checks: `flutter test`, `dart analyze`, `dart format`. Workspace lints for
  dependency direction, re-exports and fakes come with the repo skeleton.
- Each package carries its own LICENSE and NOTICE. FFmpeg ships only as LGPL
  shared libraries; never `--enable-gpl` or `--enable-nonfree`.

## 5. Platform matrix (v1)

| Area | Android | iOS | macOS |
| --- | --- | --- | --- |
| Minimum version | API 24 | iOS 15 | macOS 12 |
| Bytes cache, whole + ranged, native reader | yes | yes | yes |
| Core, image / Lottie / video decoders, frame texture | yes | yes | yes |
| Device signals | yes | yes | yes |
| Player backend | Media3 ExoPlayer → `SurfaceProducer` | AVPlayer → `AVPlayerItemVideoOutput` → IOSurface | same as iOS |
| Zero-copy video | API 29+ (ImageReader); the engine's copying path on API 24-28 | yes (IOSurface BGRA) | yes |
| Formats through the player | MP4, WebM/MKV, HLS, DASH | progressive MP4/MOV only | progressive MP4/MOV only |
| HLS | yes, through the `DataSource.Factory` | no (later: loopback proxy) | no (later: loopback proxy) |
| HDR | tone-map via `KEY_COLOR_TRANSFER_REQUEST` (API 31+), else SDR-clipped | BT.709 SDR via output colour properties | same as iOS |
| PiP | own overlay window + system PiP | system `AVPictureInPictureController` | system `AVPictureInPictureController` |
| Viewer policy (default) | `$Android` | `$IOS` | `$Desktop`, in-app overlay |
| Compression | Media3 Transformer | AVAssetReader → AVAssetWriter | same as iOS |
| Still preparation | downsampled decode, `Bitmap.compress` | ImageIO thumbnail and destination | same as iOS, progressive |
| Round video | CameraX preview → GL → MediaCodec | AVCaptureSession → AVAssetWriter | same as iOS |
| Camera session | CameraX Preview, ImageCapture, VideoCapture | AVCaptureSession, photo output, AVAssetWriter | same as iOS |
| Media library | MediaStore | PhotoKit (host opt-in) | later |
| File intake | system dialog, system camera | system dialog, system camera | system dialog, drop, paste |
| Prebuilt natives | arm64-v8a | arm64 | arm64 |

Windows and Linux: fog. Web has two columns of v1 (ADR 0011):
`mpx_library`'s intake (a file input, drop and paste) and `mpx_capture`'s
still preparation (canvas in a worker); the rest of web stays fog.
Everything needed on Apple is available from iOS 15 / macOS 12 (ADR 0004).

## 6. Open across ADRs

1. How `http_bytes_cache`'s native reader ships (a hook-built C library or a
   plugin) and how `mpx_player`'s Kotlin and Swift code link against
   it; whether it joins the prebuilt pipeline (ADR 0002, 0004, 0008).
2. `MediaKey` variants beyond `local(uuid)` and what `MediaDescriptor` keeps
   of today's `ContentDescriptor` (ADR 0001, 0003).
3. A web loading style and auto-download policy of their own (ADR 0010).
4. Linux stills for codecs the software decoder rejects: the still extractor
   over FFmpeg hardware decode behind the same fallback seam (ADR 0010).

## 7. Build order / first tickets

Vertical slices in order. Each keeps both repositories green. "After" names the
blocking tickets. Migration follows ADR 0009. Each item is one implementation
implementation issue with the same number (the implementation issue list in
chat_scroll_view's scratch area).

### Migration

1. **Native media on chat master.** Done: PR #88's content landed as PRs
   #95-#98 (2026-11-12). After: none.
2. **Hooks 2.x.** Bump `hooks` / `code_assets` to 2.x in the two native
   packages, still in the chat repo. After: 1.
3. **mpx skeleton.** New repo: pub workspace, melos config, CI running
   test/analyze/format, workspace lints (dependency direction, re-exports,
   fakes), a stub for each of the eight packages. After: 2.
4. **Media identity.** `MediaKey` / `MediaDescriptor` in `mpx_core`, modelled
   on `ContentKey` / `ContentDescriptor` without the chat variants and the pack
   reference. After: 3.
5. **Media core.** Split `catalog_assets` into `mpx_core` and fold in
   `frame_texture` and `image_decoder` with history; glyph atlas, embeds and
   presets stay behind. After: 4.
6. **Decoders with their natives.** Move with history: `lottie_decoder` +
   `lottie_native` into `mpx_lottie`, `video_decoder` + `video_native` into
   `mpx_video_decoder`; rename once: `mpx_lottie_*` / `libmpx_lottie`,
   `mpx_video_*` / `libmpx_video`, `dev.mpx.frame_texture`,
   `MPX_VIDEO_FFMPEG_DIR`; no `chat_` in ABI, asset ids, channels, worker
   names, env vars. After: 5.
7. **Bytes cache in.** Bring image_bytes_cache in as `http_bytes_cache`, renamed
   from `Image*`. After: 3.
8. **Chat switches.** chat_scroll_view takes git dependencies on mpx, moves to
   the new names in one change, deletes its copies, and maps `ContentKey` to
   `MediaKey` where it builds its stack. After: 6, 7.

### Bytes tier

9. **Progress fan-out.** Every sharer hears progress; late joiners get the last
   value; a 0 report at transfer start. After: 7.
10. **Sync peek.** `needsDownload` answers from the RAM index plus in-flight
    set. After: 7.
11. **File handout.** Path API with a lease that pins the file against eviction.
    After: 7.
12. **One disk store.** Last-use expiry, named quotas, one eviction; the host's
    separate sweeps go away. After: 11.
13. **Registered quotas.** Folders the cache does not own (Lottie frames, glyph
    pages) register as named quotas with an eviction callback; the store
    accounts their bytes and asks, the owner deletes. After: 12.
14. **Priorities.** visible > preload > background on every request, changeable
    while queued or in flight; the 6-slot queue serves by priority, then
    arrival. After: 7.
15. **Stale-while-revalidate.** Per-request policy: serve stale at once,
    revalidate in the background through ETag / Last-Modified; media defaults
    to no revalidation. After: 7.
16. **Local keys and alias.** `MediaKey.local(uuid)` in `mpx_core`;
    `alias(local, server)` and `release(local)` on the cache. After: 4, 12.
17. **Fetch adapter.** `mpx` maps `http_bytes_cache` onto
    `ContentFetcher` (key, cancel, progress, failure classes); the chat's
    still/GIF path moves onto it. After: 9, 10, 11, 8.

### Ranged resource

18. **Streaming HTTP.** Streaming bodies, `Range` / `If-Range` slots, `206` and
    `Content-Range` parsing; conditional middleware sends `If-Range` on range
    GETs. After: 7.
19. **Ranged store.** Sparse file + range-set index + strong validator, own
    quota; `200` drops spans; no `Accept-Ranges` falls back to sequential.
    After: 12, 18.
20. **Fast start.** Head prefetch with moov detection and tail fetch; one shared
    reader per resource. After: 19.
21. **Native reader.** `http_bytes_cache`'s native reader by key: reads the
    sparse file, blocks on a missing range, asks Dart to fetch it at a
    priority, wakes on the FFI "range landed" signal; `http_bytes_cache_*` /
    `hbc_*` symbols. After: 19, 14.

### Player

22. **Player API with a fake backend.** `PlayerPool`, `PlayerLease`, state
    value, per-frame playhead, policy budget; contract suite in `testing.dart`.
    After: 5, 7.
23. **Android backend.** Media3 into a per-player `SurfaceProducer`, custom
    `DataSource` over the native reader, rotation in Dart, surface cleanup.
    After: 21, 22.
24. **Apple backend.** AVPlayer + `AVPlayerItemVideoOutput` BGRA/BT.709,
    resource loader on a custom scheme over the native reader, MP4 only.
    After: 21, 22.
25. **Android API 24-28.** The engine's copying texture path below API 29;
    zero-copy from 29; HDR tone-mapping gated to API 31. After: 23.
26. **Audio owner.** One audible player app-wide; system focus; leave-screen
    callback to the host. After: 23, 24.
27. **Bubble hand-off.** Start at the bubble's position, bubble frame until the
    first player frame, position back on close. After: 26.
28. **Prepared budget and probes.** Device-class and decoder-instance gate,
    hardware probe, AV1 failure fallback. After: 23.
29. **PiP and background audio.** Hidden `AVPlayerLayer` on Apple, activity PiP
    on Android; verify the iOS background-audio rule. After: 26.

### Feed

30. **Core feed inputs.** Visible fraction, staged preload with priority and
    cancel, network/power on pause layers. After: 5.
31. **List mode.** All visible clips muted on the software path, frame advance
    floor, preload window. After: 20, 22, 30.
32. **Pager mode.** One active with sound, ±1 warm, ≤2 prepared, take-over on
    swipe. After: 31, 28.
33. **Device signals.** In `mpx` (Android, iOS, macOS): network class,
    power-saving mode, thermal status as `ValueListenable`s; the stack feeds
    the core's pause layers. After: 3.
34. **Feed signals.** Host seam for network/power/thermal/size; the example
    passes `mpx`'s signals into it. After: 30, 31, 33.
    Feed list and pager widgets land in `mpx_ui` with 31 and 32.

### Viewer

35. **Viewer skeleton, Android policy, photos.** Gallery source, origin bridge,
    morph open/close, dismiss, zoom. After: 5, 22.
36. **Viewer video.** Controls, seek bar and preview, double-tap seek, auto-hide,
    speed, quality, loop rule, GIF rule. After: 35, 27.
37. **iOS policy.** Crop reveal, two-way dismiss, iOS zoom, seek and auto-hide.
    After: 36.
38. **Desktop policy.** In-app overlay over the app window, background click
    closes, step zoom, hold-for-2x, keyboard; "fullscreen" puts the app window
    into fullscreen. After: 36.
39. **Viewer chrome and actions.** Bars, menu, caption, host actions and
    builders, thumbnail strip; host actions receive the cached file path and
    the current frame, and the example implements save and share. After: 35, 11.
40. **Viewer PiP.** Android's own window and system PiP; system
    `AVPictureInPictureController` on iOS and macOS, on the player's PiP.
    After: 29, 37, 38.

### Capture

41. **Compression.** Preset table, Transformer / AVAssetWriter, progress,
    cancel, output seam. After: 7.
42. **Round video, Android.** CameraX preview → GL → MediaCodec, preview, switch,
    pause. After: 41.
43. **Round video, Apple.** AVCaptureSession → AVAssetWriter. After: 41.
44. **Output into the cache.** Result registered under a `MediaKey.local` key
    so the sender's bubble plays at once; after upload the host aliases the
    server key to it. After: 41, 11, 16.

### Composition root

45. **mpx stack.** `MpxStack.create(...)` wires the bytes cache
    and core with defaults, takes the host's decoders, registers the host's
    quota folders; the set's README with its diagram; the example app.
    After: 6, 13, 17, 33.

### Publishing

46. **Prebuilt pipeline.** CI builds each native target into GitHub Releases
    with the LGPL disclosure; hooks pin URL + sha256 and fall back to source.
    After: 6.
47. **Pub readiness.** LICENSE/NOTICE per package, SwiftPM for plugins, renamed
    Android package ids, dartdoc and examples. After: 46.
48. **Release process.** melos versioning, manual first publish in dependency
    order, then tag-driven publishing. After: 47, and the maintainer's LGPL
    review before the native video packages.

## Addendum (2026-11-10, maintainer)

- The host or the `mpx` composition root registers the Lottie frame folder (and glyph pages, when used) as named quotas in http_bytes_cache's store; no decoder depends on the bytes cache.

## Addendum (2026-11-13, maintainer)

- Eighteen packages became eight (ADR 0001, planning ticket 27): identity, frame texture and image decoder fold into `mpx_core`; each decoder takes its native library; player backends and feed policies fold into `mpx_player`; viewer and feed widgets form `mpx_ui`; capture backends fold into `mpx_capture`; the fetch adapter and device signals fold into `mpx`. The `media_` infix is gone. `content_model` keeps `ContentKey` and takes no mpx dependency.
