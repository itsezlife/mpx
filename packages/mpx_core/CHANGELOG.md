# Changelog

## Unreleased

- `ContentView.pictureIn(root)`: the repaint boundary of a view's picture
  alone, under its status control and badge, for a surface that reads the
  picture (a viewer's origin frame). A view with a status or a badge now
  has that boundary, as a playing view had.
- `MediaDescriptor.silentLoop` marks a GIF sent as video, and
  `MediaDescriptor.isGif` tells a GIF (an animated image or a silent
  loop). The media badge times only a video: a GIF reads "GIF" whatever
  its duration, and other content (a vector animation) has no first row.
  Hosts that describe GIFs as video set `silentLoop`.
- A playing `ContentView` that a parent did not paint (a zero opacity, an
  offstage page) measures again in the frame a parent first paints it, and
  when the tickers above turn on: a view a fade-in shows plays in the next
  frame, not at the once-a-second re-measure. A view that stays hidden or
  on screen still measures nothing.
- A content has one download whatever the spec: a binding whose entry
  waits (for the user, or after a failure) reads the download another
  spec of the same content runs, and its cancel stops it. Once one spec
  has the content, the others still waiting start again and read the
  local bytes, so a tile whose viewer downloaded the content drops its
  size label and download control.
- Round video: `AssetPresets.round(diameter:, devicePixelRatio:, profile:)`
  clips a square to its circle, and `AssetPreset.isRound` tells such a
  preset. A round `ContentView` draws its preview and thumbnail enlarged
  inside the circle (`MediaStageStyle.roundPreviewScale`, 1.2) and its
  centre control at `MediaStatusStyle.roundVideoDiameter` (44, iOS 54).
  `ContentView.underlay` fills the picture's rounded area in a host colour
  until the content has faded in. `MediaStatusStyle.roundBufferingDelay`
  (500 ms, iOS 750 ms) is how long a round video buffers before a host
  shows its spinner.
- Fallback decoders: `DecoderRegistry.registerFallback(kind, decoder)`
  decodes content the kind's decoder reports as
  `DecodeFailure.unsupported` (a codec this build was built without). The
  pipeline fetches the content again and hands it to the fallback once; a
  fallback that draws a still ends the entry at `firstFrame`, final for its
  spec (`AssetProgress.bestReached`), and the still becomes the content's
  derived preview. Content with a stored derived preview is not handed to
  the fallback again. `FakeDecoder(firstFrameOnly:)` and
  `DecoderContract.run(stillsOnly:)` cover such decoders. Breaking for
  `AssetProgress` implementers: add `bestReached`. `StillImagePaintable`
  is exported.
- `ContentView.requestsDownload`: a view that is the user's request for
  its content (a page the user opened) downloads it whatever the
  auto-download policy says.
- The status control keeps its style's size whatever box it is put in: a
  large tile centres a 44 px disc instead of stretching it. A download a
  surface comes back to is drawn where its bytes got to: the scope keeps
  the most bytes any attempt of missing content reported until it is final,
  so a new attempt that counts from 0 does not reset the arc.
- `ContentView.status` (`MediaStatusMode`: `none`, `arc(radius)`,
  `control(playAction:)`, `compact`) lays the status control over the
  content, and `badge` the media badge; `onPlay` takes play taps, and
  streamable video that is not local shows play in the centre with a
  compact download control in the corner. `statusBuilder` (or the scope's)
  replaces the control. `placeholderUntil` lets the view's own placeholder
  outrank the stand-in stages up to a stage. Breaking: `loadingRadius` is
  gone; `status: MediaStatusMode.arc(radius)` replaces it, and its arc
  goes on a failure.
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
- Outline previews: `SvgPathData` reads SVG path data (no arcs), and the
  pipeline draws a descriptor's `MediaPreview.outline` as an
  `OutlinePaintable` inside `produce`. `ContentView` fills it with the
  style's `outlineFill`, or the host's tint at `outlineTintOpacity`, and
  runs the platform's `OutlineShimmer` only while shown and the clock runs
  (`OutlineLook` through `AssetPaintContext.outline`,
  `AssetBinding.paint(outline:)` and `paintStandIn(outline:)`).
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
