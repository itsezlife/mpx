# Changelog

## Unreleased

- The asset cache, fetch and decode pipeline, playback clock, frame pool and
  texture seam, keyed by `MediaKey` (`remote`, `external`, `local`, with a
  stable, file-name-safe string form), with `MediaResolver` for bare keys.
  `MediaDescriptor` carries `MediaKind`, dimensions, byte size, duration, a
  thumbnail handle, `preview`, `streamable` and `silentLoop` (a GIF sent as
  video; `isGif` tells a GIF). `AssetProfile.copyWith`.
- Platform frame texture hosts (Android, iOS, macOS) on channel
  `dev.mpx.frame_texture`, native library `libmpx_frame_texture`.
  `AssetTextureLayer` composites a binding's texture as `ContentView` does.
- Decoders: `ImageCodecDecoder` for the engine's image formats.
  `DecoderRegistry.registerFallback(kind, decoder)` decodes, once, content
  the kind's decoder reports as `DecodeFailure.unsupported`. A fallback that
  draws a still ends the entry at `firstFrame`, final for its spec
  (`AssetProgress.bestReached`), and the still becomes the content's derived
  preview. `StillImagePaintable` is exported; `FakeDecoder(firstFrameOnly:)`
  and `DecoderContract.run(stillsOnly:)` cover such decoders.
- Fetched content: `FetchedContent.ranged` is read natively as it
  downloads; `FetchedRanged.landed` and `pause` let a decoder wait for more
  bytes and pause content no surface shows. `FetchedRanged` reports its
  bytes after its spec is final, so its completion reaches every spec, and
  `FetchedRanged.rest` reports a failed rest of the download as the
  content's failed transfer. The decoder that takes fetched content
  releases it, or the pipeline when no decode does (`FetchedFile` takes an
  `onRelease`).
- Downloads: `AssetBinding.transfer` (`AssetTransfer`: `none`, `waiting`,
  `receiving` in bytes, `awaitingUser(total, received)`, `failed`), reported
  through `AssetProgress.waiting`, `transfer` and `awaitingUser`. Byte
  reports reach listeners once per frame; an unknown total reads the
  descriptor's `byteSize`. A content has one transfer record whatever the
  spec, and one download runs per content: a spec attached while another
  downloads waits for it. The record keeps the most bytes any attempt
  reported; contents nobody holds keep it for the last 256 such contents.
  Transfer and fail reports after a final stage of streamed content count
  for the content's download.
- User downloads: `AssetBinding.download()` fetches the whole content
  (`AssetDemand.downloadRequested`, `FetchRequest.whole`) and goes on with
  no surface attached until it is whole, cancelled or failed; after a
  failure it retries. `cancelDownload()` stops the fetch and keeps the
  stages; it wins over `requestsDownload` and the policy and is remembered
  per key for the scope's life.
- `AssetBinding.requestsDownload` (`ContentView.requestsDownload`): a
  surface that is the user's request for its content (a viewer page)
  downloads it whatever the policy, without making it the user's download.
  When it goes or stops asking, a download nothing else wants stops and
  keeps its bytes.
- Outside readers: `AssetCacheScope.openOutsideReader(key)` returns an
  `AssetOutsideReader` (`report(received, total)`, `close()`), a lease per
  reader outside the cache (a platform player). Its bytes are the content's
  download while no spec runs one, stay after it closes, and complete the
  content when they are all of it. Readers count: one closing leaves the
  others.
- Auto-download: `AssetCacheScope(autoDownload:)` takes an
  `AutoDownloadPolicy` (default `always`) that answers `AutoDownload.now`,
  `prefix` or `manual` per descriptor and `AutoDownloadContext`, a host tag
  passed per attach (`attach(downloadContext:)`,
  `ContentView.downloadContext`; well-known `contacts`, `privateChats`,
  `groups`, `channels`). The most permissive attached tag wins and never
  enters the cache key. Held-back content fetches only its stand-ins (and a
  4 s head for `prefix`). The answer is kept per content until the policy,
  the tags or the descriptor change. `AssetDemand` has `downloadContexts`
  and `autoDownload`; `FakeAutoDownloadPolicy` is in `testing.dart`.
- Loading stages: `AssetStage.preview` sits between `none` and
  `placeholder`. The pipeline decodes a descriptor's raster preview beside
  the fetches, blurred once with `PreviewBlur` (`AssetPipeline.previewBlur`,
  `MiniThumbnail.decode`), keeps decoded previews
  (`AssetPipelineLimits.decodedPreviews`, 256), and draws an outline
  preview (`SvgPathData`, `OutlinePaintable`, `OutlineShimmer`,
  `OutlineLook`) through `AssetBinding.paint(outline:)` and
  `paintStandIn(outline:, contentOpacity:)`.
  `ImageCodecDecoder.thumbnailBlur` (`ThumbnailBlurRule`) blurs small
  thumbnails per platform. `AssetBinding.descriptor` reads what the
  producer reported (`AssetProgress.describe`); `AssetCacheScope.know`
  hands one over before an attach.
- Previews: `PreviewStore` (`AssetPipeline.previews`; `FakePreviewStore`,
  `PreviewStoreContract`) keeps a derived preview per content, made from its
  first decoded frame (at most 40 px PNG) when the descriptor has none.
  Vector animations derive none.
- `MediaLoadingStyle` (`stages`, `badge`; `$Android`, `$IOS`, `$Desktop`,
  `forPlatform`, `copyWith`) and `MediaLoadingStyleScope`, resolved from the
  theme's platform, with a host override and `MediaStatusBuilder`.
  `MediaStageStyle` sets how `ContentView` rises through the stages;
  `ContentView.loadingStyle` overrides it. `ClearPlaceholder` is the
  scope's default placeholder; an untinted `RectPlaceholder` paints
  nothing.
- Status control: `MediaStatusControl`, the round control over media
  (disc, progress arc, download / cancel / play / pause, or a spinner),
  driven by a `MediaStatus` or a binding (`MediaStatusControl.binding`,
  `MediaStatus.forTransfer`). It keeps its style's size in any box.
  `MediaStatusStyle` (`$Android`, `$IOS`, `$Desktop`, `copyWith`) holds each
  platform's geometry and motion. `MediaStatusPainting` (`spinnerArc`,
  `progressArc`, `spinnerSweepDegrees`, `paint`, `faded`; `MediaStatusArc`)
  draws the disc, arc and spinner on a canvas.
- Badge: `MediaBadge` shows a video's duration (counting down while it
  plays), "GIF", or the size while it downloads ("1.2 / 4.5 MB", "NN%" when
  narrow) or waits for the user; `MediaBadge.binding` reads a binding.
  `MediaSizeFormat`, `MediaBadgeStrings` and `MediaBadgeStyle` per
  platform. It sits inside the picture a contain fit letterboxes.
- `ContentStatusOverlay` lays a binding's status control and badge over any
  child. `ContentView` uses it through `status` (`MediaStatusMode`: `none`,
  `arc(radius)`, `control(playAction:)`, `compact`), `badge`, `onPlay` and
  `statusBuilder`; a streamable video that is not local shows play in the
  centre and a compact download in the corner. `placeholderUntil` lets the
  view's placeholder outrank stand-ins up to a stage.
- `ContentView.pictureIn(root)`: the repaint boundary of a view's picture
  alone, under its controls (a viewer's origin frame). `ContentPicture`
  marks it when a surface has more than one view.
- Round video: `AssetPresets.round(diameter:, devicePixelRatio:, profile:)`
  and `AssetPreset.isRound`. A round `ContentView` enlarges its stand-ins
  (`MediaStageStyle.roundPreviewScale`) and sizes its control by
  `MediaStatusStyle.roundVideoDiameter`; `ContentView.underlay` fills the
  picture's rounded area until the content fades in.
  `MediaStatusStyle.roundBufferingDelay` sets the host's spinner delay.
- `AssetProfile.cornerRadius` rounds the picture as a contain fit places it
  (`roundedArea`); a texture layer is clipped to it from its first frame.
- Animation: `AssetPresets.animation` decodes at one size whatever the box,
  so a thumbnail and its fullscreen copy share one playback.
  `AssetCacheScope.playbackPosition`, `seekPlayback` and `holdPlayback`;
  `AssetPaintable.pictureSize` and `AssetCacheScope.pictureSizeOf`.
- Visibility: a playing `ContentView` measures itself after a frame in
  which something may have moved it (and once a second), and stops while no
  viewport shows it or no parent paints it. `ViewportVisibility.of` gives a
  box's visible rectangle, share, centre distance and viewports away.
- Feed inputs: `AssetBinding.visibleFraction` with
  `AssetProfile.advanceFloor`; staged preloads (`AssetCacheScope.preload`,
  `AssetPreloadStage`, `FetchRequest.prefix`); `meteredNetwork` and
  `thermalStress` pause layers through `PlaybackActivity`.
  `AssetCacheScope.holdBackground(except:)` and
  `AssetProducer.holdPreloads` hold other surfaces and preload work.
- `AssetFetcherContract` watches the failing fetch before awaiting the
  served one.

## 0.0.1

- Initial package skeleton.
