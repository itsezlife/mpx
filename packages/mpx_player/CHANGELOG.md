# Changelog

## Unreleased

- A feed slot measures itself again when it is first painted after a measure
  found it unpainted (a route built off stage for its first frame) and when
  its route becomes the top one again, so the visible clips play without a
  scroll.
- The platform players report every 100 ms while playing, with the time they
  read the position (`NativePlayerSnapshot.sampledAtUs`). The playhead moves
  at a new speed at once and then at the rate measured from those reports,
  and slews onto each report instead of stepping, so a seek bar moves
  smoothly through a speed change, even one the player takes late. A small
  disagreement is made up within a quarter of the measured rate, so it shows
  as no burst and no stall; reports are placed by the time they were read.
  Seeks, pauses, loop wraps and errors over half a second still move it at
  once.
- A failed player keeps its error through a pause or a speed change: a
  copied state stays failed with its error, never failed without one.
- Android applies a speed change at once (AudioTrack playback params).
- A failure says where it came from (the platform player and its reason, no
  playable source with the decoders that failed, opening the player), and
  the platform players log the whole error.
- A watchdog fails a player that reports playing but stops: no report, or a
  position that does not move, for 3 s (`NativePlayerBackend.stallTimeout`).
- `PlayerDiagnostics`: an opt-in lifecycle log (engines made, platform
  players released and why, the budget, the watchdog); the platform players
  log create, surface, play, pause, seek, speed and release at debug level.
- Android clears only the surface it holds when the engine takes one back,
  so a late cleanup never clears a newer surface.
- Android fixes from device runs: the JNI library is 16 KB page aligned;
  the playhead reads the duration once a pass ends and holds a settled
  seek; `PictureInPicture.stop` expands the window.
- Closing the picture in picture window pauses its player (Android, iOS,
  macOS); returning to the app keeps it playing. The example shows picture
  in picture and keeps sound in the background.
- HLS on Android: `PlayerSource.hls` (and `PlayerSource.kind`) plays a
  stream through Media3 with its playlists and segments in the bytes cache
  (`NativePlayerBackend.playlists` resolves playlists). Apple players move
  to the next source.
- `NativePlayerBackend` in `package:mpx_player/native.dart`: Media3
  ExoPlayer (Android) and AVPlayer (iOS, macOS) drawing into textures and
  reading bytes through `http_bytes_cache`'s native reader. Sources come
  from the host (`PlayerSource`, best first); a codec whose decoder failed
  on the device is skipped. Players pause when the app is hidden unless
  `backgroundAudio` is set.
- Breaking for `PlayerBackend` implementers: `pictureInPicture`
  (`PictureInPicture`, `NoPictureInPicture`). `PlayerPool` gains
  `startPictureInPicture`, `stopPictureInPicture` and `pictureInPicture`;
  the window counts as a view of its player.
- `PlayerDevice` and `PlayerDecoder`: the hardware probe
  (`NativePlayerBackend.device`) and the prepared-player gate.
- `PictureInPictureContract` and `FakePictureInPicture` in `testing.dart`.
- Breaking: `FeedPolicy` keeps only knobs the feed reads. Removed: the
  start buffer, forward buffer cap, resolution cap and quality rule (they
  come back with a native player backend), off-screen behaviour (with
  picture in picture), tray preload and diagnostics hooks (with their
  consumers), and exclusive sound (the player pool's own rule).
- `FeedPolicy.initialMute` sets a pager's starting mute; following the
  ringer reads `FeedConditions.silenced` (`FeedSignals.silenced`) until
  the user toggles.
- `FeedPolicy.pausingLayers` and `preloadBackOffLayers` are read from the
  scope's clock: nothing plays, or no preload starts, while one is set.
  `FeedPager.held` pauses the page shown.
- `FeedPolicy.heavyUnloadViewports`: a cell further from view
  (`FeedVisibility.viewportsAway`) is `FeedItemState.released`.
- Breaking: `FeedController.muted` is gone; a pager's mute is
  `FeedController.pager.muted`, and only a pager takes a start page, mute
  or advance callback. `FeedItemState.clip` is the profile a list clip
  attaches with.
- `FeedController` frees the decisions it drops, and finds an item's facts
  by index without scanning every registration.
- `AudioFocusContract` in `testing.dart`, run against `NoAudioFocus` and
  `FakeAudioFocus`.
- `FeedController` and `FeedSlot`: feed playback inside any host
  scrollable. Slots measure their own visible share against every enclosing
  viewport; the controller plans per frame, holds the preloads and the
  pager's leases, and exposes each item's `FeedItemState`. `FeedScope`
  hands a controller to the slots below. In pager mode the most visible
  page plays, so any pager works.
- `FeedActiveItemRule.pick`: the in-view choice, shared by the list planner
  and the pager.
- The planners and `FeedPager` take facts that may be unknown (`itemOf`
  returns null): such items are neither played nor warmed.
  `FeedPager.itemCount` is settable and `FeedPager.replan` plans again.
- `PlayerPool`, `PlayerLease`, `PlayerState`, `PlayerBudget`, `PlayerView`.
- `PlayerBackend` / `PlayerEngine` seam; `FakePlayerBackend` and
  `PlayerEngineContract` in `testing.dart`.
- `FeedPolicy` (`list` and `pager` defaults, 25 knobs), `FeedItem`,
  `FeedConditions` and `FeedListPlanner`.
- `FeedSignals`: the host seam for network, power saving and thermal state,
  with `metered`, `powerSaving` and `stressed` for the core's pause layers.
- `FeedPagerPlanner` and `FeedPager`: the pager mode over the pool;
  `FeedPolicy.boundPreload` shared with the list planner.
- One sound owner: `PlayerPool.soundOwner`, `onSoundOwnerLeftScreen`, and
  the `AudioFocus` seam on `PlayerBackend` (`FakeAudioFocus` in tests).

## 0.0.1

- Initial package skeleton.
