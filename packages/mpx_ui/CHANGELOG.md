# Changelog

## Unreleased

- `MediaViewer`: a fullscreen photo viewer that opens from and closes to its
  origin, with `ViewerPolicy.$Android` (morph, dismiss drag, zoom) and host
  `ViewerTokens`; seams `GallerySource` and `OriginBridge`, with
  `FakeGallerySource` and `FakeOriginBridge` in `testing.dart`.
- Viewer chrome (`ViewerChrome`): top bar, "N of M" counter, caption,
  thumbnail strip and overflow menu; host `ViewerAction`s get the item's
  cached file (`ViewerFile`, released after the action) and the current
  frame. `FakeViewerFile` in `testing.dart`.
- `FeedListView`: a list that plays every visible clip muted and preloads
  the items ahead, by a list-mode `FeedPolicy`; it plans again when its
  `FeedSignals` change.
- `FeedPagerView`: a pager over `FeedPager`; posters stand in until the
  first frame, neighbours preload to their stage.

## 0.0.1

- Initial package skeleton.
