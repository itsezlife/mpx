# Changelog

## Unreleased

- `MediaViewer`: a fullscreen photo viewer that opens from and closes to its
  origin, with `ViewerPolicy.$Android` (morph, dismiss drag, zoom) and host
  `ViewerTokens`; seams `GallerySource` and `OriginBridge`, with
  `FakeGallerySource` and `FakeOriginBridge` in `testing.dart`.
- `FeedListView`: a list that plays every visible clip muted and preloads
  the items ahead, by a list-mode `FeedPolicy`; it plans again when its
  `FeedSignals` change.

## 0.0.1

- Initial package skeleton.
