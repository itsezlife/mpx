# Changelog

## Unreleased

- A viewer video page paged away from keeps the picture its player showed
  last as its stand-in, as an origin's frame, until its content has a frame
  of its own: a video still downloading no longer falls back to its blurred
  preview beside the page shown, and its player fades in over that picture
  when the page is back.

- A viewer video's centre shows one control: the buffering spinner takes
  the play button's place, the button fading out as the spinner fades in
  and taking no taps meanwhile (`ViewerBufferingSpinner.presence`,
  `ViewerVideoControls.centreTaken`).

- A `ViewerOrigin`'s frame is the picture of the `ContentView` in it
  alone: the status control and the badge over a tile no longer ride the
  open morph or stand in on the page. A picture inset in its thumbnail
  keeps its place in a frame of the thumbnail's size.

- Feed clips load in stages: the default poster is the item's staged view
  with its `FeedItem.downloadContext`, the player fades in over the poster
  for the viewer policy's time, and a pager page shows the buffering
  spinner past the delay (`FeedClip.showsBuffering`; a list shows none).
  `FeedListView` and `FeedPagerView` tell the cache each
  `FeedItem.descriptor` before the item is preloaded or attached.
- Viewer pages load in stages: the origin's frame stays over the content's
  preview and thumbnail until its first frame; without one the preview,
  then the thumbnail, fitted to the media's proportion on the black page.
  `GalleryItem.descriptor` reaches the cache before a page attaches, and
  `GalleryItem.downloadContext` is the page's auto-download tag.
- `ViewerPolicy.loading` (`ViewerLoadingRules`, with `copyWith` and each
  platform's values): the page shown has a status control
  (`ViewerPageStatus`: a spinner or an arc for a photo, cancel and an arc
  for a video, download when it waits or failed); a player that buffers,
  or has no first frame, shows `ViewerBufferingSpinner` after 500 ms; the
  player fades in over the picture for the policy's time.
- Opening the viewer is the user's request for its content: the page shown
  downloads it whatever the auto-download policy said in the list
  (`ContentView.requestsDownload`). A video paged to, and the neighbours,
  follow the policy.
- A page of an item not loaded yet, and a page whose content shows
  nothing, are the black page with nothing on it, never a box.
- `MediaViewer` holds every other surface and the preloads while its open
  and close morphs run (the item that morphs plays on).
- `MediaViewer` leases the opened video's player before the morph's first
  frame, so its way to a first frame overlaps the morph, and prepares the
  video items beside the one shown, paused, up to the pool's prepared
  budget (`ViewerVideoRules.prepareNeighbours`): paging to one shows its
  first frame at once.
- A video that fails says so over its picture with a retry
  (`ViewerVideoFailure`, `ViewerVideoStrings.failed` and `retry`), not a
  black page. The speed presets are 48 px targets sharing the row, with press
  feedback and the chosen one marked (`ViewerTapTarget`); the speed slider is
  48 px tall.
- The viewer's origin frame is a placeholder the content replaces, no longer
  drawn under transparent content.
- An animation's page draws the surface's own playback
  (`AssetPresets.animation`). While a video with sound plays, the surface's
  loop of it stands still. `ViewerVideoRules` says where the player starts
  (`start`: the beginning by default), what the loop does on close
  (`originReturn`: to the player's place, from its start, or where it
  paused) and what an animation does on open (`loopOpen`: goes on, starts
  over, or plays its own); each platform's policy has its own. The morph
  shows the player both ways; the origin's picture shows until the player
  moves, then the player fades in over it and the picture is no longer
  painted. The player and the picture share one box and one fit, and the
  origin's frame is placed as the origin fitted the picture, so the morph
  shows no rim.
- `ViewerPolicyScope` and `copyWith` on the policy and every value in it: a
  host changes a field and keeps the platform's others. With no policy the
  viewer takes the scope's, else the reference of the theme's platform.
  `MediaViewer.videoStartOf` and `onVideoLeft` for a host's saved place.
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
