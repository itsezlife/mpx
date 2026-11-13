# Changelog

## Unreleased

- The viewer's origin frame is a placeholder the content replaces, no longer
  drawn under transparent content.
- An animation's page draws the surface's own playback
  (`AssetPresets.animation`). While a video with sound plays, the surface's
  loop of it stands still; the player starts where the loop is and the loop
  goes to the player's place on close, or both start over and resume, as
  `ViewerVideoRules.start` and `originReturn` say (`$Desktop`: from the
  beginning, resuming). The morph shows the player both ways.
- The morph keeps the content's proportion from end to end
  (`GalleryOrigin.fit`, `ViewerOrigin.fit` for a tile that shows the picture
  whole).
- The video bar keeps the seek track's length as the time and speed change;
  the speed panel shows the speed beside its slider; viewer text takes the
  viewer's style whatever the host puts above it.
- Breaking: `GalleryOrigin.frame` is gone; `OriginBridge.frameOf` hands
  out a picture the caller owns and disposes. The viewer frees its copies
  as it leaves the pages, and the scope keeps one only while an origin is
  hidden, so a picture is never painted after it is freed.
- `ViewerController` tells its listeners after the frame when the viewer
  mounts or unmounts, instead of during the build.
- `MediaViewer` moves to a new `source` or `bridge` when rebuilt with one.
- `FeedClip` draws what the controller decides (`FeedItemState.clip`,
  `released`) instead of branching on the mode; `FeedPagerView.muted` is
  null by default, leaving the policy's initial mute.
- `ViewerOrigin` measures through `ViewportVisibility` (mpx_core).
- `OriginBridgeContract` in `testing.dart`, run against
  `ViewerOriginScope` and `FakeOriginBridge`.
- Breaking: `MediaViewer.show` takes the platform's policy when none is
  given (was `ViewerPolicy.$Android`) and, without a bridge, the closest
  `ViewerOriginScope`.
- `ViewerOrigin` and `ViewerOriginScope`: origins in any list, grid or
  bubble, registered by gallery index or media key; the scope is the
  `OriginBridge`, so a host writes none.
- `ViewerController` (`MediaViewer.controller`, `MediaViewer.show`):
  index, open state, controls, zoom reset, the video's lease, close.
- `ViewerPolicy.forPlatform`.
- Embeddable pages: `ViewerPhotoPage`'s dismiss drag, max zoom, content size
  and zoom callback are optional; `ViewerVideoPage` plays one video with the
  policy's gestures and controls, over `ViewerVideoSession`, the video logic
  `MediaViewer` uses too.
- `FeedClip`: the closest `FeedSlot`'s media, a `PlayerView` while it holds
  a player, else the cached clip at its visible fraction.
- `FeedListView` and `FeedPagerView` are built on `FeedController`,
  `FeedSlot` and `FeedClip`. `FeedListView.itemExtent` is optional: items
  may have any extent. `FeedListViewState.feed` and
  `FeedPagerViewState.feed` expose the controller. `FeedPagerView`'s page
  that plays (and `onPageChanged`) is the most visible page.
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
- Viewer video (`MediaViewer.players`): hand-off from the origin,
  `ViewerVideoControls` (play, seek bar with preview, time, speed, quality),
  double-tap seek, auto-hide, hold for speed, the loop rule; GIFs loop
  muted. `ViewerQuality`, `ViewerSpeeds`, `ViewerVideoStrings`.
- `ViewerPolicy.$IOS` (crop reveal, two-way dismiss with velocity, fill
  zoom) and `ViewerPolicy.$Desktop` (in-app overlay, background click
  closes, step zoom, keyboard and wheel, host fullscreen through
  `onFullscreenChanged`).
- `OriginBridge.handBack` and `GalleryOrigin.position`;
  `GalleryItem.hasAudio`.
- `FeedPagerView`: a pager over `FeedPager`; posters stand in until the
  first frame, neighbours preload to their stage.

## 0.0.1

- Initial package skeleton.
