# Changelog

## Unreleased

- Library grid: `LibraryGrid` over a media library album, with
  `LibraryGridPolicy.$Android` / `$IOS` (columns, gaps, corners, check,
  selection motion, badges, swipe select, camera slot), the picker
  selection seam `PickerSelection` and its default `OrderedPickerSelection`,
  `LibraryGridCell`, `LibraryGridTokens` and `LibraryGridLabels` from the
  host, and a camera slot the host fills (`CameraSlotBuilder` with
  `CameraSlotSignals`).
- Library picker: `LibraryPicker` with `LibraryAlbumSwitcher`, the access
  states (not determined, denied, restricted, limited and partial banners,
  camera denied, not allowed, empty) in the host's `LibraryPickerLabels`,
  and the picker-mode viewer `PickerViewer` (`LibraryGallerySource`,
  `PickerViewerChrome`, `PickerViewerItem`).
- `MediaViewer`: a fullscreen photo and video viewer that opens from and
  closes to its origin, with seams `GallerySource` and `OriginBridge`
  (`FakeGallerySource` with `insert(index, item)`, `FakeOriginBridge` and
  `OriginBridgeContract` in `testing.dart`). `MediaViewer.show` takes the
  platform's policy and the closest `ViewerOriginScope` when none is given;
  a rebuild with a new `source` or `bridge` moves to it. While the open and
  close morphs run, other surfaces and preloads are held.
- `ViewerController` (`MediaViewer.controller`): index, open state,
  controls, zoom reset, the video's lease, close; it tells listeners after
  the frame when the viewer mounts or unmounts.
- `ViewerPolicy` (`$Android`, `$IOS`, `$Desktop`, `forPlatform`, `copyWith`
  on it and every value) and `ViewerPolicyScope`: morph, dismiss, zoom,
  keyboard and wheel, fullscreen through `onFullscreenChanged`.
- Origins: `ViewerOrigin` and `ViewerOriginScope` register origins in any
  list, grid or bubble by gallery index or media key, measured through
  `ViewportVisibility`. An origin's frame is the picture of its
  `ContentView` alone, without the status control or badge, and a
  placeholder the content replaces. `OriginBridge.frameOf` hands out a
  picture the caller owns and disposes; `handBack`, `GalleryOrigin.position`
  and `fit` keep the content's proportion through the morph.
- Viewer chrome (`ViewerChrome`): top bar, "N of M" counter, caption,
  thumbnail strip and overflow menu; host `ViewerAction`s get the item's
  cached file (`ViewerFile`, `FakeViewerFile`) and the current frame.
- Viewer video (`MediaViewer.players`): `ViewerVideoControls` (play, seek
  bar with preview, time, speed, quality), double-tap seek, auto-hide, hold
  for speed, GIFs muted in a loop; `ViewerQuality`, `ViewerSpeeds`,
  `ViewerVideoStrings`, `ViewerTapTarget`. `ViewerVideoRules` sets the start
  (`start`), the loop on close (`originReturn`), an animation on open
  (`loopOpen`) and `prepareNeighbours`. The opened video's player is leased
  before the morph's first frame, and neighbours are prepared paused.
  `MediaViewer.videoStartOf` and `onVideoLeft` keep a host's place. A failed
  video shows `ViewerVideoFailure` with a retry.
- Embeddable pages: `ViewerPhotoPage` and `ViewerVideoPage`, over
  `ViewerVideoSession`.
- Viewer loading: `ViewerPolicy.loading` (`ViewerLoadingRules`). The page
  shown has a `ViewerPageStatus` (a spinner or arc for a photo, cancel and
  an arc for a video, download when it waits or failed), rebuilt after a
  frame in which it heard a change. A video's page shows one centre
  control: the status until the player's first frame (the
  `ViewerBufferingSpinner` holds back while it shows), then play / pause,
  with the spinner taking the button's place while it buffers
  (`ViewerBufferingSpinner.presence`, `suppressed`;
  `ViewerVideoControls.centreTaken`). The origin's frame stays over the
  preview and thumbnail until the first frame; a page paged away from keeps
  its player's last picture as its stand-in. A page with nothing to show is
  black.
- Viewer downloads: the item the viewer opened on (by its content key) asks
  for its content whatever the auto-download policy
  (`ContentView.requestsDownload`); other pages follow the policy. A
  download only the page started stops on close or paging away and keeps
  its bytes. `GalleryItem.descriptor` reaches the cache before a page
  attaches; `GalleryItem.downloadContext` is the page's tag;
  `GalleryItem.hasAudio`.
- `FeedListView` (plays every visible clip muted, preloads ahead, any item
  extent) and `FeedPagerView` (the most visible page plays; `muted` null
  keeps the policy's initial mute), built on `FeedController`, `FeedSlot`
  and `FeedClip` (`FeedListViewState.feed`, `FeedPagerViewState.feed`).
  `FeedClip` draws what the controller decides (`FeedItemState.clip`,
  `released`): a `PlayerView` while it holds a player, else the item's
  staged view with its `FeedItem.downloadContext`, the player fading in over
  it. Each `FeedItem.descriptor` reaches the cache before the item preloads
  or attaches.
- Feed status: `FeedClip(status:, badge:)`, and `status` / `badge` on
  `FeedListView` and `FeedPagerView`, lay the status control and badge over
  an item whatever draws it, over a `ContentPicture`. A `FeedPagerView` page
  with a status control shows one centre control; otherwise it shows the
  buffering spinner past the delay (`FeedClip.showsBuffering`).

## 0.0.1

- Initial package skeleton.
