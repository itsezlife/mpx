# ADR 0011: Device library, intake, preparation and picking

A host shows the device's photo library and lets the user pick from it, takes
files from outside the library, and prepares picked media for upload. mpx
holds all of it, in three packages. A new plugin, `mpx_library`, owns the
**media library** (access, albums, paged assets, change observation, the
original's file) and the **file intake** (system file dialog, system camera,
drag and drop, paste). `mpx_capture` gains **media preparation** (still
downscale and JPEG, video presets per platform, thumbnails and metadata) and
a live **camera session** with a minimal full-screen capture surface.
`mpx_ui` gains a **library grid**: selection with order numbers and swipe
select, a camera slot, an album switcher, access and empty states, and a
picker-mode viewer built from the viewer's composable pieces. The grid hands
the host an ordered selection; mpx knows nothing of chats, messages, captions
or sending.

**Status**: Accepted (decided with the maintainer 2026-11-20)
**Relates to**: 0001, 0002, 0003, 0006, 0007, 0010
**Amends**: 0001 (package set and edges), 0007 (scope, presets, still
preparation, camera), 0006 (picker mode as a composition, no structural change)

## Context

chat_scroll_view needs a media picker (its ADR 046). Its teardown of the four
reference clients (chat_scroll_view `.scratch/media-picker/research/`, file and
line per value) shows one split on every platform: a container with caption
and send, pages, data loaders, an ordered selection, a send plan. Only the
container, caption and plan are chat concerns. The library, the intake, the
grid and the encoders are media concerns any app has (a profile photo picker,
a document scanner, a social feed composer), and the encoders and cameras are
already mpx's. A first draft kept the library and the grid in the chat. The
maintainer moved them here so that other hosts get them and the chat keeps
only what is a chat's.

## Decision

### Packages

| Package | Kind | Gains |
| --- | --- | --- |
| `mpx_library` (new) | Plugin, optional | **Media library** seam and its Android (MediaStore) and iOS (PhotoKit) adapters; **file intake** seam and its adapters on Android, iOS, macOS and web; library keys and a `ContentFetcher` for thumbnails and originals; fakes and contract suites in `testing.dart` |
| `mpx_capture` | Plugin, optional | **Media preparation** with `PreparationPolicy.$Android` / `$IOS` / `$Desktop` / `$Web`; the 432 px preset; a **camera session** (preview texture, photo, video, switch, flash, pause, hand-off) and a minimal **capture surface** |
| `mpx_ui` | Flutter, optional | **Library grid** with `LibraryGridPolicy.$Android` / `$IOS`, the **picker selection** seam and its default, the **camera slot**, the **album switcher**, access and empty states, the **picker-mode viewer** |

The set is nine packages. `mpx_library` stands as a package for 0001's
*platform permissions* reason: photo library access, and the camera through
the system camera intent.

### Dependency direction

Arrows point at the dependency. New or changed edges are marked `*`.

```
mpx_lottie         -> mpx_core
mpx_video_decoder  -> mpx_core
mpx_player         -> mpx_core, http_bytes_cache
mpx_library      * -> mpx_core
mpx_ui           * -> mpx_player, mpx_core, mpx_library
mpx_capture        -> mpx_core, http_bytes_cache
mpx                -> mpx_core, http_bytes_cache
```

- `mpx_ui` takes no edge to `mpx_capture`. The grid reserves the camera
  cell's span and calls a host builder (the **camera slot**) with the cell's
  pause signals; the host fills it with `mpx_capture`'s preview. A host that
  shows a viewer or a grid without a camera never links CameraX, Media3
  Transformer or the AVFoundation capture code.
- `mpx_library` takes no edge to `http_bytes_cache`: an original is a file
  lease the platform hands over; the host stores captured or pasted bytes
  through `mpx_capture` or its own cache.
- `mpx` takes no edge to `mpx_library` (0001's rule for optional layers).

### Cost of the `mpx_ui -> mpx_library` edge

A viewer-only host now links `mpx_library`'s plugin code. It must cost that
host no permission and no store review flag:

| Rule | Detail |
| --- | --- |
| No manifest permissions | `mpx_library`'s Android manifest declares none; the host declares `READ_MEDIA_IMAGES`, `READ_MEDIA_VIDEO`, `READ_MEDIA_VISUAL_USER_SELECTED` and `READ_EXTERNAL_STORAGE` (API ≤ 32) when it uses the library. The README lists them |
| Opt-in Apple code | PhotoKit and the system camera compile only when the host opts in through a build define (name settled in implementation, `MPX_LIBRARY_PHOTOS` / `MPX_LIBRARY_CAMERA` style); without it the adapter reports `restricted` and the camera intake is unavailable. The host adds the usage strings when it opts in |
| Drop and paste dependency | `super_drag_and_drop` (with its clipboard reader) brings a prebuilt native core. A viewer-only host links it too; if that cost is ever refused, intake splits into its own package under 0001's heavy-native reason. Not in v1 |

### Media library

| Area | Decision |
| --- | --- |
| Seam | `MediaLibrary`: `access` (listenable), `requestAccess`, `manageSelected`, `openSettings`, `albums`, `page(album, offset, limit)`, `changes`, `original(asset, onProgress)` returning a file lease |
| Library access | `notDetermined`, `denied`, `restricted`, `limited` (iOS: the user chose some items; "Manage" re-opens the system choice), `partial` (Android 14+: `READ_MEDIA_VISUAL_USER_SELECTED`; `manageSelected` asks again so the system shows its choice), `full`. Re-read on app resume |
| Library albums | The all-media album first (Android: All media, All photos, All videos, Camera, then buckets by recency; iOS: Recents, Favorites, non-empty smart albums, user albums reversed), each with a cover, a count and `startsAtEnd` (iOS albums other than Recents open at the end) |
| Paging | A **library page** is a window by offset in the album's order (Android: newest first by modified date, taken date on API ≤ 28; iOS: Recents newest first, other albums oldest first). Pages are queried off the main thread; nothing holds the whole library in memory |
| Changes | Inserted / removed / changed per album, or reload. Android: content observers on images and video, debounced 2 s; iOS: `PHChange` details, observer registered only once authorised |
| Library asset | Platform id, kind (photo, video), subtypes (live, slow motion, time-lapse, favourite, screenshot, animated), dimensions, duration, created and modified dates, MIME when known |
| Identity | A library asset is `MediaKey.external('device-library:<platform id>')`; a thumbnail is its own key with the pixel size in it, so the asset cache keeps sizes apart. No new `MediaKey` variant |
| Fetcher | `LibraryFetcher implements ContentFetcher`: thumbnails from the platform thumbnail API at the requested pixels (iOS opportunistic with network on demand), originals as files with download progress for cloud-held assets (`needsDownload` true only for those). The host composes it ahead of its network fetcher |
| Platforms | Android and iOS in v1. A macOS PhotoKit adapter is later; desktop and web hosts use the intake alone |

### File intake

| Route | Decision |
| --- | --- |
| System file dialog | `pickFiles(filter, multiple)` on Android, iOS, macOS and web (and the desktop platforms the dialog plugin covers). Filters: all files, images and video. Web: a hidden file input with `accept` and `multiple`; a pick is dropped when the window returns from idle with nothing within 1000 ms. A web file is a blob handle |
| System camera | `captureWithSystemCamera(kind)`: Android `ACTION_IMAGE_CAPTURE` / `ACTION_VIDEO_CAPTURE`, iOS `UIImagePickerController` camera; a local file back. The fallback when the camera session is unavailable |
| Drag and drop | A drop region widget reporting enter, over, leave and drop with the dragged types and local files. macOS, iOS, Android and the other desktops through `super_drag_and_drop`; web through DOM events with enter/leave counting and a 500 ms watchdog. Files only; non-local URLs rejected; a size ceiling from the host. Safari's missing types are reported as unknown files |
| Paste | A clipboard reader for files and image data (`super_drag_and_drop`'s clipboard reader) and a mapping from plain fields (bytes with a MIME, or a path) to intake files, so a host whose text field already reads pasted media (chat_scroll_view's rich clipboard) hands it over without a dependency either way |
| Intake file | A path or a blob handle, with name, size, MIME, modification time, and a de-duplication key (name, size, modified) |
| Classification | A helper from MIME, extension and probe facts to photo, video, animation (GIF, silent looping video), audio or file |

### Media preparation (`mpx_capture`)

The host calls `MediaPreparer.prepare(input, intent, policy)` per item before
upload, off the UI isolate, two items at a time. Intents: as photo (standard
or high quality), as video (a preset), as file (original bytes, a thumbnail
only). The result is a `PreparedMedia`: a local key or file lease,
dimensions, duration, thumbnail bytes, MIME, `hasAudio`, progress and cancel.

**Stills**

| Policy | Long side (HQ) | JPEG (HQ) | Thumbnail | Other |
| --- | --- | --- | --- | --- |
| `$Android` | 1280 (2560) | 80 (99) | 90 px at 55 | Downsampled decode |
| `$IOS` | 1280 (2560) | 60 (60) | 320 px at 40 | ImageIO; HD changes the size only |
| `$Desktop` | 1280 (2560) | 87, progressive | 320 px at 87 | An original JPEG at or under 4 bits per pixel that needs no downscale is kept |
| `$Web` | 2560 | 90 | Poster 720 px at 90 | Re-encode only past 2560, for PNG/BMP over 2 MB or a format the server does not take; a result over 6 MB is re-encoded at 90; canvas in a worker |

**Video.** 0007's table gains one row, used by `$Android` only:

| Preset | Max side | Video kbps | Audio kbps / channels |
| --- | --- | --- | --- |
| 432 (new) | 432 | ≤ 750 | 32 / 1 |
| Very low | 480 | 400 | 32 / 1 |
| Low | 640 | 700 | 32 / 1 |
| Medium | 848 | 1600 | 64 / 2 |
| High | 1280 | 3000 | 64 / 2 |
| Very high | 1920 | 6600 | 64 / 2 |

The source-bitrate ceiling of 0007 applies to every row.

| Policy | Offered presets | Default |
| --- | --- | --- |
| `$Android` | From 432, 640, 848, 1280 by the source's long side: > 1280 four, > 854 three, > 640 two, else one | The remembered choice for that count (the host stores it), at most 848; a file of 1000 MB or more is not compressed |
| `$IOS` | 480, 640, 848, 1280, 1920, clamped to the source | The remembered preset, else Medium |
| `$Desktop`, `$Web` | None | No transcode; the video goes as it is, with a thumbnail and its metadata |

**Probe**: dimensions, duration, audio track, animated (GIF, silent video).

### Camera session and capture surface (`mpx_capture`)

| Area | Decision |
| --- | --- |
| Session | `CameraSession`: open front or back, a preview texture through `mpx_core`'s texture host, `capturePhoto`, `startRecording` / `stopRecording`, `switchCamera`, flash, `pause` / `resume`, state (`available`, `denied`, `failed`), a frame-rate cap for small previews (30 fps), dispose. One session per process; a second open takes it over |
| Hand-off | The running session moves from a small preview (the grid's camera slot) to the capture surface and back without a restart |
| Capture surface | Minimal: shutter (tap for a photo, hold for video), switch camera, flash, close. No modes strip, zoom dial or dual camera in v1 |
| Output | `MediaKey.local(uuid)` into the bytes store, as 0007 *Into the cache* |
| Platforms | Android CameraX; iOS and macOS AVCaptureSession; iOS turns audio off during a call |

### Library grid (`mpx_ui`)

| Area | Decision |
| --- | --- |
| Grid | A fixed-extent sliver grid over a library album's pages: cells never measure; thumbnails through `ContentView` with a preset per cell pixel size; a screen of prefetch; nothing decoded far off screen; scroll physics from the host |
| Policy | `LibraryGridPolicy.$Android`: 3 columns portrait, 4 landscape or tablet, 2 dp padding and gap, first-row outer corners 16 dp, check 24 in a 26 frame with a 42 hit, selected image scales to 0.787 over 200 ms, video badge bottom-left, disabled alpha 0.3. `$IOS`: 3 portrait, 5 landscape, 1 pt gap, cells `floor((w - (n-1)) / n)`, check 29 with slop 8 and a 0.5 s spring, duration bottom-right, GIF and subtype icons. `forPlatform`; a host may pick either |
| Picker selection | A seam: `orderOf(key)` (1-based, re-indexed on removal), `toggle(key)`, `toggleRange(keys)` (every key crossed takes the state the first took), a gate that may refuse a key with a typed reason (cap, kind), a change signal. `OrderedPickerSelection` is the default: ordered by selection, a cap the host sets (unbounded when unset), single select. A host with its own selection implements the seam |
| Swipe select | `$Android`: long-press then drag. `$IOS`: horizontal pan from x > 44 that fails if \|dy\| > 5 before \|dx\| > 8; scrolling off while active. Auto-scroll at the edges |
| Camera slot | Index 0 of the all-media album, one column by two rows. The grid owns placement (`$Android`: the all-media album only; `$IOS`: at 3 columns only, never in other albums, never when the host says the camera is denied or media is not allowed) and the pause signals (viewer open, page inactive; off screen is told but never pauses: a pause closes the camera and its reopen blocks frames), and calls the host's builder with them. Tap and long-press go to the host |
| Album switcher | `$Android`: a drop-down of cover, name and count rows; `$IOS`: a menu from the title. Choosing rebinds and scrolls to the top (to the end for `startsAtEnd`) |
| States | Loading, empty, not determined (request on first show), denied (Android: an empty view with camera and access buttons; iOS: a placeholder with Open Settings), restricted, limited (iOS: a Manage banner, Select more / Change settings), partial (Android 14: the chosen items with a banner that calls `manageSelected`), not allowed (a host text, grid hidden), camera denied (iOS: a banner, no camera slot; Android: the slot's builder is told). Strings from the host |
| Changes | Library change events update the grid without losing the selection; `$Android` defers them while the picker-mode viewer is open |
| Semantics | Kind, duration, date and selection state per cell, with an "Open" action; RTL through `Directionality`, the check at the top end |
| Refusals | A refused toggle is reported to the host (`onRefused(key, reason)`); the package plays no feedback beyond the policy's haptic |

### Picker-mode viewer (`mpx_ui`)

Built from 0006's composable pieces, not a fork: `ViewerPhotoPage`,
`ViewerVideoPage` / `ViewerVideoSession`, a `ViewerOrigin` on each grid cell
under a `ViewerOriginScope`, over a `GallerySource` backed by the album's
pages. The picker chrome: a top-end check that goes through the picker
selection and its gate, a counter, and a bottom slot the host fills (a
caption field and a send button in a chat; nothing in a profile picker). With
nothing checked, the host's bottom-slot action receives the current item. The
grid cell under the viewer hides while open. The viewer structure, policies
and seams of 0006 do not change; a slot the composition lacks is added to
0006's pieces, not to a second viewer.

### What stays with the host

Captions, sending, grouping, upload, what the selection becomes, rights and
caps, the container the grid sits in (a sheet, a page, a dialog), feedback for
refusals, strings, where captured media is saved, and the remembered video
preset.

## Why

- The library, intake, grid and encoders are what any app that picks media
  needs; the caption and send plan are what only a messenger needs. The line
  falls between them.
- `mpx_library` is a package of its own for the same reason `mpx_capture` is:
  a platform permission a host may not want. Keeping it out of the core keeps
  `mpx_core` free of photo-library code.
- Preparation and the camera join `mpx_capture` because they use its encoders,
  permissions and preset table; a boundary between them would save no host
  anything.
- A camera slot instead of an `mpx_ui -> mpx_capture` edge keeps 0001's rule
  that a host that skips capture never links it, while the grid still owns
  where the camera goes and when it pauses.
- A selection seam lets a host count picks from the library, files and the
  camera in one order, while a simple host takes the default.
- The 432 preset is the Android reference's lowest step; offering 480 in its
  place would send larger files than users of that platform get today.
- iOS sends a library photo at JPEG 0.6 at both sizes (chat_scroll_view
  `.scratch/media-picker/research/ios-jpeg-quality.md`).

## Rejected

| Alternative | Why not |
| --- | --- |
| Library, intake and grid in the chat | Every other host would rebuild them; none of it knows a chat |
| The library in `mpx_core` | Puts photo-library permissions and code in every host's core |
| One `mpx_picker` package with library, grid and camera | Puts Flutter UI and camera natives in front of a host that wants only the library seam |
| `mpx_ui -> mpx_capture` for the camera cell | Every viewer host would link CameraX, Transformer and AVFoundation capture |
| Intake in its own package in v1 | Its routes share the intake file and classification with the library's originals; split only if the drop plugin's cost is refused |
| A preparation package beside `mpx_capture` | Same encoders and permissions |
| 480 in place of 432 | Larger outputs than the Android reference |
| A `MediaKey.library` variant | `external` already means "media from outside the host's backend"; a closed-set change costs every consumer |
| The grid owning the selection outright | A messenger counts files and captures in the same order numbers |

## Consequences

- **0001**: nine packages; `mpx_library` joins the package table (kind:
  plugin, optional; owns the library and the intake) and the *platform
  permissions* row of *When a package boundary stands*; the edges gain
  `mpx_library -> mpx_core` and `mpx_ui -> mpx_library`; *Optional layers*
  names `mpx_library` beside `mpx_ui` and `mpx_capture`. `AGENTS.md` and
  `docs/spec.md` follow (package table, edges, platform matrix).
- **0007**: in-app capture for regular photo and video moves into v1 (the
  camera session and the minimal capture surface); still preparation joins
  compression; the preset table gains 432; "camera and microphone permissions
  live only here" gains an exception: `mpx_library`'s system camera intake
  needs the iOS camera usage string, with no session.
- **0006**: no structural change; the picker-mode viewer is a composition of
  its pieces with a check, a counter and a host bottom slot.
- **Platform matrix**: web gains a column for `mpx_library`'s intake and
  `mpx_capture`'s still preparation; the rest of web stays fog.
- New glossary terms for mpx's spec: media library, library access, manage
  selected, library album, library asset, library page, file intake, intake
  file, media preparation, preparation policy, camera session, capture
  surface, library grid, picker selection, camera slot, picker-mode viewer.
- chat_scroll_view moves its mpx pin once these land (its ADR 046).

## Settled in implementation

- **Camera preview texture.** The camera session's preview is a texture
  from the Flutter texture registry (an Android `SurfaceProducer` CameraX
  renders into; a `FlutterTexture` over the capture session's
  IOSurface-backed buffers), as round video's is, not a texture of
  `mpx_core`'s frame texture host. That host is a CPU write path: a texture
  is a pixel buffer a decoder locks, fills and posts through C entry
  points. A camera is a GPU producer; through the host every frame would be
  converted (YUV to RGBA on Android) and copied on the CPU, with JNI code in
  `mpx_capture` to reach the C lock, for a preview that runs as long as the
  grid shows. Hand-off keeps the same texture, so the host's hold and
  fresh-frame rules have nothing to do; clipping and corners come from the
  widgets.
- **The camera cell never pauses for scrolling**: the slot hears it is off
  screen, but only the viewer covering it or an inactive page pauses the
  session (a pause closes the camera; reopening reconfigures the capture
  session and blocks the app's main thread for 150-240 ms). The Android
  session binds preview and photos only; the video use case (its encoder)
  is bound when a recording starts and unbound when it ends.
- **One camera owner per process** across the camera session and round
  video: opening either takes the camera from the other (a session turns
  closed, a recording fails as taken over and its file is deleted).
- **Drop and paste on native platforms** through `super_drag_and_drop` and
  `super_clipboard` 0.9. Their native core pins `device_info_plus` < 12 and
  so `win32` 5; the mpx example takes `share_plus` 12 (13 needs `win32` 6).
  A host on `share_plus` 13 waits for the 0.10 line, which needs Flutter
  3.44.
- **Web still preparation** lives in `mpx_capture` (`WebPreparationCodec`):
  `createImageBitmap` resizes and `OffscreenCanvas.convertToBlob` encodes
  off the main thread, so no worker; outputs stay in memory.
- **Picker-mode viewer** is `MediaViewer` itself under a route that lays
  `PickerViewerChrome` (check, counter with the selected strip, host
  bottom slot) over it, paging a `LibraryGallerySource` over the grid's
  pages; the grid's cells are `ViewerOrigin`s, which hide the cell while
  the viewer covers it. No piece of 0006 needed a new slot. The origin
  comes back at once on close (the morph lands on it), not with a 0.3 s
  fade.
- **Library videos play in place**: `MediaLibrary.playable` hands the
  platform's URI of a video (Android's MediaStore content URI, the iOS
  original's file URL from PhotoKit), and `PlayerSource.local` has the
  native player open it directly: no copy of the original, nothing through
  the bytes cache. `LibraryPlayerSources.of` answers a host's players for
  library keys; without players the picker-mode viewer shows stills.
- **Selected-items preview**: `PickerSelectionPreview` shows the selection
  in order, deselects on its number, opens on a tap and reorders on a long
  press drag through a host callback (`OrderedPickerSelection.move`), so the
  `PickerSelection` seam is unchanged. The host swaps it in for the grid
  when the selection's counter is tapped.
- **Library picker**: `LibraryPicker` composes the album switcher, the
  access states and banners, the grid and the picker-mode viewer; the host
  places the switcher through `headerBuilder`.
- **Opt-in define names**: `MPX_LIBRARY_PHOTOS` and `MPX_LIBRARY_CAMERA`
  as Swift active compilation conditions on the `mpx_library` target (the
  mpx example's Podfile shows how).

## Open in implementation

- How the opt-in defines reach Swift Package Manager builds.
- Whether the grid's swipe select auto-scroll speed comes from the policy or a
  fixed curve.
- A macOS library adapter over PhotoKit.

## Provenance

chat_scroll_view ADR 046 and `.scratch/media-picker/` (spec, tickets 04-09,
14-17, 27; research `android-desktop.md`, `desktop-notes.md`, `ios-web.md`,
`web-notes.md`, `ios-jpeg-quality.md`). The 432 bitrate ceiling is the
Android reference's `MediaController.makeVideoBitrate` cap for a short side
under 480 (750 kbps); the offered-preset counts are its `PhotoViewer`
compression count rule. Maintainer decisions of 2026-11-20: the package
split, the 432 preset, the minimal capture surface, drop and paste through
`super_drag_and_drop`.

## Related

ADR 0001 (topology), 0006 (viewer pieces), 0007 (capture), 0010 (thumbnail
stages in the grid).
