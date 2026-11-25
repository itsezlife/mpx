# Changelog

## Unreleased

- The viewer's player starts with sound: a player a list left muted (volume 0,
  kept warm) opened silent in the viewer.
- `FeedClip.onPlay`: a clip the autoplay gate holds (a setting, the power
  saver, a size over the limit) shows play over its picture, with the host's
  action behind it (`FeedController.requestPlay` for a clip that plays in
  place, the viewer for a video); a clip that plays, or is paused for a
  moment, shows none.
- The badge and the status control `FeedClip` lays over a clip fade with the
  viewer's morph, as every mark over an item does (`ViewerOriginOverlay`).
- Closing on a video stands its player still on the frame the origin's loop
  is handed, with its position and picture: the loop takes up at the frame the
  flight shows, with no step back or forward as the picture lands.
- The thumbnail strip is drawn and moved as the usual strip is
  (`ViewerThumbnailStrip`, `ViewerStripLayout`): the thumbnail on show is as
  wide as its picture at the strip's height (between 42 and 84) with a gap of
  8 on each side and the strip keeps it in the middle; it follows a page swipe
  as the finger moves (the item that goes shrinks as the next one grows, the
  row moves with it); a tap on a thumbnail, or a jump of the item, moves the
  focus over 200 ms (100 ms to the next), easing out, growing the new item and
  shrinking the old; a drag along the strip scrubs through the items and
  settles on the one it stops at, and a strip of ten items or more is carried on
  by a fling (the platform's deceleration), stopping against its ends. The
  strip comes in with a fade of its own (200 ms) besides the chrome's. The
  thumbnails are decoded once at the
  grown size, not at every size they pass through.
- The play button fades while the caption is over it and comes back when it
  is not (`ViewerVideoControls.captionTop`).
- The parts of the chrome animate when the item changes, by default: the title, the subtitle and the counter slide 8 px the way the
  item went over 320 ms (ease-out-quint), the caption crossfades over 200 ms.
  `ViewerChrome.titleTransition`, `subtitleTransition`, `counterTransition`
  and `captionTransition` take a `ViewerChangeTransition` (`slide`, `fade`,
  `none` or a host's own), and `ViewerChangeSwitcher` gives a host's own
  widget over the viewer the same change.
- The controls keep shown while a finger is down anywhere on the viewer and
  the wait starts again when it leaves (every touch cancels the hide, and it is scheduled on release); a caption scrolled away from its start
  keeps them too.
- Closing a zoomed picture flies from the picture as it is drawn (zoom and pan
  included) to its origin in one motion instead of
  jumping to its fitted size first.
- `ViewerSystemBars` is `keep`, `hideStatusBar` (the default: only the status
  bar goes with the controls, as a messenger's viewer does) or `hideAll`.
- The caption is a scroll view over the room between the top bar and the video
  controls (`ViewerCaptionSheet`): its text starts as
  low as five lines (two in landscape) and a drag up takes it over the picture,
  the box behind it growing, then scrolls it. It gives under a pull past an end
  (a move followed by the share of the room not yet given, and its
  spring) even when all of the text shows, its edges fade while there is
  more, and the picture above its box takes the touches. The caption and the video bar hide as one block: they
  slide by the same amount over the same time.
- The chrome and the video controls fade in with the open morph instead of appearing when it ends.
- The video's settings button is in the top bar (`ViewerChrome.settingsIcon`),
  and the settings panel closes on a tap outside. The controls do not hide by
  themselves while the settings or the overflow menu is open.
- The viewer's speed control is a button beside the seek bar that goes
  through `ViewerSpeedRule.cycle` (1x, 1.5x, 2x by default, back to the first
  after the last), and a settings button under the top bar that lists every
  `ViewerSpeedRule.presets` speed and the qualities. The slider and the
  panel under the caption are gone; the quality button moved to the
  settings. `ViewerVideoStrings.settings` is the new button's label.
- `ViewerSystemBars` (`MediaViewer.systemBars`): by default the system bars
  hide with the viewer's controls and come back, edge to edge, with them and
  when the viewer closes; `keep` leaves them to the host.
- Paging in the viewer moves the hidden cell with the page: the cell of the
  item left shows again, and the item the viewer is on is the one that is
  empty, so a dismiss drag over another item no longer shows its cell twice.
- The viewer's time reads whole (with its total) under a host text style
  with letter spacing.
- The viewer's seek bar is a piece of its own: `ViewerSeekController` (the
  playhead, the preview a finger moves, the seek made when it leaves) and
  `ViewerSeekBar`, drawn as a `ViewerSeekBarStyle` says. The viewer looks and
  behaves as before; a host that draws its own video surface (a reels page)
  takes the same bar and restyles it instead of copying its rules.
- What a video that cannot be played shows is the policy's
  (`ViewerVideoRules.failure`): `silent` (a picker's:
  the page keeps its picture and play tries again), `alert` (Open in
  another app or Cancel, where the host gives `MediaViewer.onOpenElsewhere`;
  the card without it), or `card` (the old card with Retry, now
  `ViewerVideoFailureCard`). A failed video keeps play in its centre.
- A surface's overlays on the item the viewer shows (a cell's check and
  marks) fade back only once the close has landed, with the picture back
  in its place, not as the close starts.
- Paging onto a video no longer flashes: its loop is held on the page's own
  picture, not on the origin cell's frame of another moment, which every
  surface of the content (the page under the player included) swapped to
  and back as the player faded in. The open still holds on the origin's
  frame, the picture the morph flies.
- `GalleryItem.standIn`: a sharp still (a recording's first frame) a viewer
  page draws under its picture when it has no frame of its own to stand in,
  so paging back to a video whose player was let go never shows black while
  a new one starts. A picker's captures carry their poster
  (`PickerCaptureKeys.standInOf`).
- Follows mpx_core's rename: every `ContentView` here is an `AssetView`.
- `ViewerBackdropScope` / `ViewerBackdropZoom`: a viewer with no
  `onBackdropScale` of its own reports its backdrop scale to the scope
  above its navigator, and every `ViewerBackdropZoom` under it draws its
  surface at it (1.1 open on `$Android`, rolled back by a dismiss drag, 1
  again as the close lands), so a picker's or chat's viewer zooms what it
  covers with no host code beyond the two widgets.
- `OriginBridge.setCovered` and `ViewerOriginOverlay`: what a surface draws
  over an item (the grid cell's check and marks) fades out while the viewer
  shows that item and back as it pages away or starts closing
  (`LibraryGridPolicy.viewerOverlayFade`, 180 ms decelerating). An
  `OriginBridge` implementation adds `setCovered`.
- The swipe selection's edge auto-scroll is `EdgeAutoScroll`, a headless
  session a host can drive under its own list. It keeps the finger on the
  screen: a finger held still at the bottom of a grid in a part-raised sheet
  goes on raising the sheet to its top and then scrolls the grid, where it
  used to stop after a few steps as the grid moved under the finger. Swipe
  moves are read against the grid where it is now (an event's own local
  position is through its place at the down). `$Android` takes the
  usual speed: 80 bands, a step half as deep as the finger is in one
  (`LibraryGridPolicy.autoScrollMaxStep`).
- `PickerSelectionPreview`'s list fills the preview, so the area past the
  picks takes drags too.
- The picker-mode viewer's videos neither autoplay nor loop: a page shown
  waits paused at the start with play shown, and a video played to its end
  is back at its start, paused, play shown. `ViewerVideoRules.autoplay`
  and `ViewerVideoRules.loopNever`; `PickerViewer.videoRules` is the
  picker's rule set, and `PickerViewer.show(video:)` /
  `LibraryPicker.viewerVideo` let a host adjust it. The chat viewer's rules
  are unchanged. A player a policy leaves paused shows its first frame
  sharp over the blurred picture as soon as it is drawn.
- The viewer's selected strip runs on `PickerStripController`, a headless
  behaviour a host can drive with its own row: a deselected item fades where
  it stood (120 ms) while the rest slide into the gap (250 ms) and the shade
  closes with them; a lifted item held within 32 of an end scrolls the row
  through a `PickerStripScrollTarget`. The strip shows a video's duration
  on a bar along the bottom. `PickerViewer.show` / `LibraryPicker` take the
  strip's policy (`PickerStripPolicy`, none for no strip), a builder that
  replaces its look, and `assetOf` for selected items the viewer's album
  has not read. `LibraryPickerState.pages` is the album the grid shows.
- The viewer's selected strip and `PickerSelectionPreview` show a capture
  by its `PickerCapture.thumbnail` when it has one (a recording's first
  frame), as the grid does.
- `PickerCapture.thumbnail`: a still (a recording's first frame) that
  stands for a capture in the grid's cells.
- The viewer over the camera (`PickerViewer.show(overCamera:)`, used by
  `openCaptures` and the first capture): no grid origin, no dismiss drag,
  and a close slides the picture off downwards, fading
  (`ViewerPolicy.plainCloseSlides`). The swipe selection's edge bands sit
  on the grid's part on screen, so a grid reaching below the screen
  auto-scrolls at the screen's bottom.
- The swipe selection's edge auto-scroll drags the list
  (`ScrollPosition.drag`, a step of up to 16 a frame) instead of jumping
  it: a host's position takes it as a user scroll (a sheet rises first, and
  lowers when the scroll goes back past the start), and the drag ends at
  rest when the auto-scroll stops.
- The camera's capture flow: `LibraryPickerState.openCaptures` opens the
  viewer on the newest capture, `PickerViewerItem.close` lets a slot close
  the viewer, `LibraryPicker.onViewerClosed` tells the host it closed.
- Input guards: a viewer close while it opens is ignored, and the picker
  opens one viewer at a time.
- `LibraryGridPolicy.captureViewerEvery` / `opensViewerOnCapture`: on
  `$IOS` the viewer also opens on every 10th capture.
- Captures in the picker: `LibraryPicker.captures` (a host's listenable
  list of `PickerCapture`, keyed by the capture's `MediaKey$Local`, with
  kind, size and duration) shows them first in the grid, newest first, with
  a library item's cell, marks and selection number, and pages them first
  in the viewer. The first capture opens the viewer on it
  (`opensFirstCapture`). `PickerCaptureKeys` maps either kind of item to its
  key; `LibraryGrid.captures`, `LibraryGallerySource(captures:)`.
- `ViewerVideoRules.restarts`: a video plays from its beginning each time
  the viewer comes to it, paged back to or opened again; the picker-mode
  viewer sets it, the gallery keeps a warm player's position.
- `CameraSlotSignals.shouldPause` no longer pauses the camera cell when it
  scrolls off screen (only the viewer over it or an inactive page do): the
  pause and resume closed and reopened the camera while scrolling.
- The picker-mode viewer's bottom slot hears the chrome:
  `PickerViewerItem.chromeShown` (where the chrome heads), `chrome` (its
  fade) and `dismissing` (a dismiss drag under way), also
  `ViewerController.dismissing`.
- `LibraryPicker.viewerBottomSlotHoldsKeyboard` (`PickerViewer.show` and
  `PickerViewerChrome.bottomSlotHoldsKeyboard`): a host dock that holds the
  keyboard's and the safe area's place sits on the screen's bottom edge,
  never lifted; the viewer's controls still stand on its height.
- `ViewerPolicy.controlsReturnOnSpringBack`: the picker-mode viewer's
  chrome comes back when a dismiss drag springs back without closing.
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
