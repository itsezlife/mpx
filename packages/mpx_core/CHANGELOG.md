# Changelog

## Unreleased

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

## 0.0.1

- Initial package skeleton.
