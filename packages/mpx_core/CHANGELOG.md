# Changelog

## Unreleased

- `PreviewStore` (`AssetPipeline.previews`; `FakePreviewStore` and
  `PreviewStoreContract` in `testing.dart`): content whose descriptor has
  no preview reads a stored one, and derives one from its first decoded
  frame (at most 40 px, PNG, unblurred, once per content per process)
  when the store has none. Vector animations derive none.
- `MediaLoadingStyle` (`stages`: `MediaStageStyle`; `$Android`, `$IOS`,
  `$Desktop`, `forPlatform`, `copyWith`) and `MediaLoadingStyleScope`,
  resolved from the theme's platform. `ContentView` rises through stages
  as the style says: a thumbnail fades over its preview, content over
  `stageFade` (or `gifFade` for a playing loop) with Android's 5 %
  scale-in, the desktop swaps at once, a raster preview gets the desktop
  wash, and an outline or a stand-in under a vector animation fades out
  (`AssetBinding.paintStandIn(contentOpacity:)`). `ContentView.loadingStyle`
  overrides the resolved style.
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
