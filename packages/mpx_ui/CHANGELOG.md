# Changelog

## Unreleased

- `ViewerVideoRules.centreWhilePlaying`: the picker-mode viewer leaves the
  centre empty over a playing video and shows play when it pauses; its
  info line comes back when the viewer pages back to the video.
- Picker-mode viewer: a tap on a photo toggles its selection
  (`LibraryGridPolicy.viewerTapSelects`), a tap on a video plays or pauses
  it, and neither hides the chrome. `MediaViewer.onPictureTap` lets a host
  take a picture tap; the gallery viewer's tap is unchanged.
- Order numbers step down to fit three or more digits. The grid's marks
  follow each platform (a play mark before a video's duration, a live
  photo's corner mark, HD on a checked photo with `highQuality`, GIF on
  iOS) as `LibraryAssetMarks`, which the selected-items preview reuses
  (`assetOf`). The preview animates removals and scrolls under a lifted
  item near an edge. The album switcher's arrow is the platform's.
- `ViewerVideoRules.autoHides`: whether a video's controls hide by
  themselves. The picker-mode viewer's chrome never does: it fades in with
  the open, out with the close and on a tap, and stands on top and bottom
  scrims that run under the status bar, with no band behind its bar.
- `LibraryPicker` reads the albums again on a library change (covers and
  counts follow) and drops selected items the library no longer holds
  (`onRemoved` lets a host take them instead). The picker-mode viewer has a
  top bar: back, the host's title (`viewerTitle`), a video's info line on
  `$Android` (`viewerSubtitleOf`, `PickerViewer.videoInfo`), the count and
  the check.
- Picker-mode viewer: the check and the count as a numbered circle and an
  outlined pill on one line; the selected strip shows an item on a tap,
  deselects on its check, reorders on a long press drag (`onReorder` on
  `LibraryPicker` and `PickerViewer.show`) and outlines the item shown; the
  host's bottom bar sits at the bottom, lifted by the keyboard, with the
  viewer's video controls above it.
- Every route, overlay and popup the picker and the viewer push, and the
  grid, the picker and the selected-items preview themselves, draw their
  text from the host's text style or the theme, never the fallback
  (underlined, monospace). `testing.dart`: `expectThemedText`,
  `unthemedHost`. Every close of the viewer fades its chrome.
- `LibraryGridLookup`: the asset of the grid's row at a scroll offset (the
  nearest one held while its page loads, `LibraryPages.nearestAt`), for a
  host that labels places in the grid, a date beside a scroll thumb say.
  `LibraryPicker` passes it, a `controller` and a `gridBuilder` that wraps
  the grid alone, below the header, through to its grid.
- `PickerSelectionPreview`: the selected items in their order, a tap on
  the number deselects, a tap opens, a long press drags to reorder
  (`OrderedPickerSelection.move`).
- `LibraryPlayerSources.of`: a library video's player source, so the
  picker-mode viewer plays library videos on the host's players.
- A library reload or an app resume updates the grid in place, and closing
  the viewer on another item never scrolls the list.
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
- `GalleryPager` replaces the viewer's and the feed pager's `PageView`: one
  gesture owner decides once, from the down point, between a pinch, a pan
  of a zoomed picture, a dismiss drag (tested first) and a page drag, and
  swallows the distance that decided it; a zoomed picture pinned at its
  edge hands the rest of the pan on to the next page. Its values are
  `GalleryPagerPhysics` (claim, release, settle, ends, side taps),
  `GalleryPageTransition` (`stack`, `strip` with parallax, `instant`),
  `GalleryTapRules` (the double-tap wait, fired at the second press) and
  `GalleryKeepAlive`; pages attach `GalleryPageGestures` under a
  `GalleryPageScope`. `ViewerPolicy` gains `pager`, `transition`, `taps`,
  `dismissRatio`, `dismissClaim`, `zoomFocal`, `zoomFling`, `zoomBounce`
  and `pictureClickCloses`; `ViewerVideoRules` gains `doubleTapZooms` and
  `clickPlays`, `ViewerHoldSpeed` `minDuration`. `ViewerPhotoPage.onHoldStart`
  returns whether it took the press. Existing code that expected
  `ViewerPolicy.$Android` to dismiss downward only, or `$IOS` to close past
  a twelfth of the height, now sees both ways and a quarter.
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
  an item whatever draws it, over a `ContentPicture`, at the corner of the
  picture as it shows (a playing clip's cover fit fills the cell). A
  `FeedPagerView` page with a status control shows one centre control;
  otherwise it shows the buffering spinner past the delay
  (`FeedClip.showsBuffering`).

## 0.0.1

- Initial package skeleton.
