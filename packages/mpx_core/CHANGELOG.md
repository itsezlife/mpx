# Changelog

## Unreleased

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

## 0.0.1

- Initial package skeleton.
