# Changelog

## Unreleased

- `MediaBadge`: the label over media with its duration ("0:13", counting
  down while it plays) or "GIF", and its size while it downloads ("1.2 /
  4.5 MB", "NN%" when narrow) or waits for the user ("4.5 MB");
  `MediaBadge.binding` reads it all from a binding. `MediaSizeFormat`
  (`$Android` "1.2 MB / 4.5 MB", `$IOS` "1.2 / 4.5 MB", `$Desktop` tenths
  of a megabyte), `MediaBadgeStrings` (English defaults) and
  `MediaBadgeStyle` per platform, in `MediaLoadingStyle.badge`.
- `MediaStatusControl`: the round control over media (disc, progress arc,
  download / cancel / play / pause icon, or a spinner), driven by a plain
  `MediaStatus` or by a binding (`MediaStatusControl.binding`, which maps
  the transfer with `MediaStatus.forTransfer` and taps to `download()`,
  `cancelDownload()` or `onPlay`). It morphs, smooths its arc and comes
  and goes on its own ticker, and repaints rather than rebuilds on
  progress. `MediaStatusStyle` (`$Android`, `$IOS`, `$Desktop`,
  `copyWith`) holds each platform's geometry and motion;
  `MediaLoadingStyle` groups it and `MediaLoadingStyleScope` resolves it
  from the theme's platform, with a host change and a host
  `MediaStatusBuilder`.
- Downloads have a state and verbs. `AssetBinding.transfer`
  (`AssetTransfer`: `none`, `waiting`, `receiving` in bytes, `awaitingUser`,
  `failed`) replaces `downloadProgress`; an unknown total reads the
  descriptor's `byteSize`, and byte reports reach listeners once per frame.
  `download()` fetches now (and retries a failure); `cancelDownload()`
  stops the content fetch, keeps the stages, and is remembered per key for
  the scope's life. A failed download reads `failed` instead of keeping a
  spinning arc, and `ContentView.loadingRadius` hides its arc on failure.
  Breaking: `AssetProgress.download(fraction)` is replaced by `waiting()`,
  `transfer(received, total)` and `awaitingUser()`.
- Auto-download: `AssetCacheScope(autoDownload:)` takes an
  `AutoDownloadPolicy` (default `AutoDownloadPolicy.always`) that answers
  `AutoDownload.now`, `prefix` or `manual` per descriptor and per
  `AutoDownloadContext`, an opaque host tag a surface passes per attach
  (`attach(downloadContext:)`, `ContentView.downloadContext`; well-known
  `contacts`, `privateChats`, `groups`, `channels`). The most permissive tag
  of the attached bindings wins, and the tag never enters the cache key.
  `AssetPipeline` fetches only the stand-ins (and a 4 s head for `prefix`)
  of missing content the policy holds back; the policy's `changes` and a
  more permissive attach start it. Breaking: `AssetDemand` implementers add
  `downloadContexts` and `autoDownload`. `FakeAutoDownloadPolicy` is in
  `testing.dart`.
- `AssetStage.preview`, between `none` and `placeholder`: `AssetPipeline`
  decodes a descriptor's raster preview beside the fetches (no fetch slot),
  blurred once with `PreviewBlur` (`$Android`, `$IOS`, `$Desktop`,
  `forPlatform`; `AssetPipeline.previewBlur`), and keeps decoded previews
  (`AssetPipelineLimits.decodedPreviews`, 256) so a re-attach draws its
  preview in the attach frame. `MiniThumbnail.decode` takes a
  `PreviewBlur`. `ImageCodecDecoder.thumbnailBlur` (`ThumbnailBlurRule`)
  blurs fetched thumbnails below 101 / 201 / 240 px per platform. Each
  rise keeps the stand-in it replaced (preview, then thumbnail) for
  `AssetBinding.paintStandIn`.
- `MediaDescriptor.preview` (`MediaPreview.raster` bytes or an
  `outline` path) and `streamable`. `AssetBinding.descriptor` reads the
  content's descriptor once the producer reports it
  (`AssetProgress.describe`, called by `AssetPipeline` for known and
  resolved descriptors), and `AssetCacheScope.know` hands one to the
  producer before an attach. Breaking: `AssetProgress` and `AssetProducer`
  implementers add `describe` and `know`.
- `ClearPlaceholder`, which paints nothing, is the scope's default
  placeholder: media no longer waits behind a light box. Breaking:
  `RectPlaceholder.fallbackColor` is gone and an untinted `RectPlaceholder`
  paints nothing. A `ContentView`'s own placeholder also stands in while a
  profile that does not autoplay its first frame waits for the full asset.
- `AssetCacheScope.holdBackground(except:)` leaves the given content
  playing, and while a background hold is on the producer starts no
  preload work: breaking, `AssetProducer.holdPreloads` is new, and
  `AssetPipeline` holds its preload fetches and decodes in their queues.
- A playing `ContentView` measures where it is only when something may have
  moved it (a scroll position around it, the window, its attach), in one
  pass after that frame, and every playing view once a second; a still
  screen of playing cells no longer walks its viewports every frame.
- A playing `ContentView` measures itself after each frame and is hidden
  when no viewport shows it, so cells laid out and painted off screen (a
  shrink-wrapped grid in a list) stop playing; a hidden binding painted
  anyway paints at the time it hid.
- `FetchedRanged.landed` and `FetchedRanged.pause`: a decoder that finds
  its bytes missing tries again when more landed, and pauses the fetching
  of content its surface stopped showing.
- `FetchedContent.ranged`: content read natively as it downloads. Fetched
  content has a release point: the decoder that takes it releases it once
  it no longer reads it, the pipeline releases content no decode takes, and
  `FetchedFile` takes an `onRelease`. `ImageCodecDecoder` releases a file
  once the engine has it in a buffer.
- `ViewportVisibility.of`: a box's rectangle, the clip of every viewport
  around it, its visible share, centre distance and how many viewports away
  it is, in one walk. The feed slot and the viewer origin measure with it.
- `AssetProfile.copyWith`.
- `AssetTextureLayer` is exported: a host's own render object composites a
  binding's texture exactly as `ContentView` does.
- `MediaKey` (`remote`, `external`, `local`) with a stable, file-name-safe
  string form, and `MediaDescriptor` with `MediaKind`, dimensions, byte size,
  duration and a thumbnail handle.
- The asset cache, fetch and decode pipeline, playback clock, frame pool and
  texture seam, keyed by `MediaKey`, with `MediaResolver` for bare keys.
- Platform frame texture hosts (Android, iOS, macOS) on channel
  `dev.mpx.frame_texture`, native library `libmpx_frame_texture`.
- `ImageCodecDecoder` for the engine's image formats.
- Feed inputs: `AssetBinding.visibleFraction` with `AssetProfile.advanceFloor`;
  staged preloads (`AssetCacheScope.preload`, `AssetPreloadStage`, distance
  order, `FetchRequest.prefix`); `meteredNetwork` and `thermalStress` pause
  layers fed through `PlaybackActivity`, which hold back staged preloads.
- `AssetFetcherContract` watches the failing fetch before awaiting the
  served one, so a fetcher that fails it first passes.
- `AssetPresets.animation`: content that plays decodes at one size whatever
  the box, so a thumbnail and its fullscreen copy share one entry and one
  playback. `AssetCacheScope.playbackPosition` and `seekPlayback` read and
  move an entry's playback (the seek hands over the picture at the position);
  `holdPlayback` stops it on its frame while something else plays the
  content.
- `AssetPaintable.pictureSize` and `AssetCacheScope.pictureSizeOf`: the size
  of the picture an entry draws, for a surface that places the content
  before it knows its size.
- `AssetProfile.cornerRadius` rounds the picture as a contain fit places it
  (`roundedArea`), not the box it is letterboxed in.

## 0.0.1

- Initial package skeleton.
