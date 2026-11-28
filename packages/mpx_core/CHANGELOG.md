# Changelog

## Unreleased

- `TrackedTransfers.readBytes(key)`: the whole content's bytes, for a
  keeper that lends no file (the web).
- An animation that arrives over a first frame the view already shows (its
  own still, or a sibling's it borrowed at the attach) swaps in at once
  instead of fading in from nothing: a sticker or custom emoji opened at a
  new size (a preview, an embed in text) no longer blinks out and fades
  back.
- Tracked transfers: the `TrackedTransfers` seam (`download(key, origin:)`
  with `TransferOrigin.user` / `auto`, `watch(key)`, `cancel(key)`,
  `leaseFile(key)` lending a `ContentFileLease`). `AssetCacheScope(tracked:)`
  takes one: the download of a surface attached with `tracksTransfer: true`
  (an `AssetView` whose status is the full or the compact control) goes
  through it, once per content, and every surface of the content reads its
  transfer from `watch`; cancel goes to `cancel(key)`. Thumbnails, previews,
  glyphs and surfaces without such a control stay the scope's own fetches,
  and a scope without the seam downloads as before. The bindings report
  `binding.trackedDownload`, `cancelForwarded` and `untracked`;
  `binding.mapped` is the seam implementation's to report, with the job.
- `AssetTransfer.sending(sent, total)` and `AssetTransfer.sent`: an upload
  whose source is the content, and its end before the content is
  published. Only a tracked transfer reports them. Code that switches
  exhaustively over `AssetTransfer` needs the two cases.
- The status control shows an upload: `sending` is a ring of the bytes sent
  with a cancel (`MediaStatus.upload`, read as "Cancel upload",
  `MediaStatusStrings.cancelUpload`) that goes to the seam's `cancel(key)`,
  and the badge reads "sent / total"; `sent` shows no ring and keeps the
  picture. Code that compares `MediaStatus` values sees the new field.
- Media preparation: the `MediaPreparation` seam (`prepare(input, intent)`
  returning a `PreparationHandle` with progress, the `PreparedMedia` and
  cancel; failures `PreparationCancelled` and `PreparationFailed(code)`).
  `PreparationInput`, `PreparationIntent`, `CompressionPreset`,
  `PreparedKind` and `PreparedMedia` moved here from `mpx_capture`, compare
  by value, and `PreparedMedia` gained `thumbnailPath`.
  `PreparationInputCodec`, `PreparationIntentCodec` and
  `PreparedMediaCodec` are their stored form, version 1, for journals and
  reuse tables.
- `testing.dart`: `FakeTrackedTransfers`, `FakeMediaPreparation`, and the
  `TrackedTransfersContract` and `MediaPreparationContract` suites.
- Diagnostics events: `MpxDiagnostics.current`, one process-wide policy the
  host sets at start (`silent` by default, `developer` logging under `mpx`,
  or `onEvent` with a `minLevel`), and `MpxEvent` (level, an operation from
  the reporting package's own `DiagnosticOp` enum and its category, the
  `jobId` / `itemId` / `mediaKey` / `tag` ids, a few numeric, boolean or
  short string fields, error and stack trace). `emit` builds its fields
  only when the level is enabled; a sink that throws is ignored. The core's
  own operations are `BindingOp`. `MpxTrace` adds `Timeline` sections named
  `mpx.<category>.<op>` behind the `mpx.trace` define, compiled out by
  default. `testing.dart` has `RecordingDiagnostics` (`install` restores
  the previous policy after the test), `isMpxEvent` and the
  `MpxDiagnosticsContract` suite.
- `AssetLoadState.standsStill`: a binding that asked for motion and settled on
  a picture that does not move (a video its decoder could not play, shown by
  its first frame).
- A streamable video that is not local shows play in the centre only where
  the host gives an `onPlay` to stream it and the content waits for the
  reader; a download that runs, or a surface with no `onPlay` (a feed tile),
  shows its arc and cancel, as any other content.
- `MediaSpinnerStyle.motion`: `MediaSpinnerMotion.chase` is the platform's
  spinner (the head grows accelerating, the start jumps by the longest sweep
  and the tail decelerates onto the head), `swing` the sine it was. The
  Android styles chase.
- A still's decode no longer follows its box pixel by pixel. `AssetPresets`
  rounds each side up to a ladder of sizes, three to an octave (... 320,
  410, 512, 640 ...), and `AssetCacheScope.attach` draws a finished still up
  to twice as large instead of decoding a smaller spec. Dragging a desktop
  window decodes once per rung the box grows across, and nothing as it
  shrinks. Presets now decode slightly larger than their box (a 200 px
  circle is decoded at 205 px), and `isAttached` / `contains` answer for the
  covering still's spec.
- `AssetViewSkin.failure`: what a view shows over its picture while its
  media failed, given the state and the stock part, which is nothing (the
  picture stays; the status control's download is the
  retry).
- A GIF's download arc is its measured arc again: before its bytes are
  measured it stands at nothing and turns, as a GIF cell does, and
  never swings as the video loading's spinner, which the shared status
  control had given it. The choice is per kind of media in the skin
  (`MediaProgressLook`, `AssetViewSkin.progress`; stock: a GIF, an animated
  image or a GIF sent as a silent video loop, keeps the measured arc, a
  video spins).
- **Breaking:** the loading state is headless and the look a skin.
  `AssetLoadState` (the stage and the download, with `loading`, `fraction`,
  `failed`, `shown`, `status()`) is what the stock chrome reads;
  `AssetViewSkin` replaces the status control, the badge or the picture's
  entrance, each builder given the state and the stock part
  (`AssetView.skin`, `AssetStatusOverlay.skin`,
  `MediaLoadingStyleScope.skin`, the view's parts over the scope's);
  `AssetLoadStateBuilder` hands the state of any media (or of a binding a
  caller holds) to a host's own widget. `statusBuilder` and
  `MediaStatusBuilder` are gone: a status builder is
  `AssetViewSkin(status: (context, state, stock) => ...)`.
- **Breaking:** `ContentView` is `AssetView`, and its helpers follow:
  `AssetFrame` (with `AssetFrame$Picture`, `$StandIn`, `$Surface`),
  `AssetPicture`, `AssetStatusOverlay`. The view of one asset cache binding
  is named by the core's own vocabulary (`AssetCacheScope`, `AssetPreset`,
  `AssetBinding`); no alias is kept.
- One shimmer band across the screen: `OutlineLook.sweep` is the span the
  highlight crosses, in the paint's coordinates. `ContentView` passes the
  screen, so outline previews side by side draw one band, not one per cell.
  A surface that paints outlines itself passes its own screen span.
- `ImageCodecDecoder` reports data it cannot decode whose first bytes are an
  SVG document as `DecodeFailure.unsupported`, so a vector decoder
  registered as the still kind's fallback draws it. A still is handed to its
  fallback even when it has a stored derived preview.
- `MediaKind.vectorImage`: a resolution-independent still (SVG), decoded by
  the decoder a host registers for it (`mpx_svg`); the pipeline treats it as
  a still.
- Content rising over a view's outranking placeholder
  (`ContentView.placeholderUntil`) fades in over it and the kept stand-in,
  both opaque, instead of cross-fading with the placeholder; a viewer that
  opened from a thumbnail no longer dips toward its background.
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
  `ContentView.loadingStyle` overrides it. Content fades in at its size on
  every platform (`contentScaleIn` 0); a host may set a scale-in. `ClearPlaceholder` is the
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
  platform. It and the compact status control sit inside the picture as
  the view's fit shows it: the picture a contain fit letterboxes, the box a
  cover fit fills.
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
