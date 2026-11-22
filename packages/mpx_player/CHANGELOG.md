# Changelog

## Unreleased

- No free decoder is no failure of the video. Android no longer remembers
  a codec as failed when its decoder would not start for a format the
  device plays (other players held the decoders; an 8K session can take
  the whole decoder): the engine fails with `PlayerDecoderBusy`. The pool
  then gives a player on screen the decoders of the players off screen and
  starts it again, once; one off screen lets its engine go and waits to be
  shown, never failed.
- A player prepared ahead (paused, not played yet) loads past its buffer
  cap until its first frame shows: an 8K clip filled the 2 MiB cap before
  its first picture was decoded and never became ready, spinning until a
  play lifted the cap.
- Android: a player keeps at most a quarter of the Java heap buffered
  (Media3's video default, about 131 MB, outgrew a 256 MB heap on a long
  high-bitrate recording and ended in an OutOfMemoryError).
- `PlayerAudioFocus` (`exclusive`, `duck`, `mix`) on `NativePlayerBackend`:
  how an audible video takes the sound from other apps. By default Android
  plays over the music that plays (`mix`) and Apple platforms take the
  sound (`exclusive`).
- `PlayerSource.local` (`PlayerSourceKind.local`): a file on the device (a
  `file:` URL, an Android `content:` URI) the platform player opens in place,
  past the bytes cache. `PlayerSourcesOf` may answer with a future, for a
  host that looks a source up first.
- `PlayerPool`, `PlayerLease`, `PlayerState`, `PlayerBudget`, `PlayerView`
  over the `PlayerBackend` / `PlayerEngine` seam (`FakePlayerBackend`,
  `PlayerEngineContract` in `testing.dart`). One sound owner:
  `PlayerPool.soundOwner`, `onSoundOwnerLeftScreen` and the `AudioFocus`
  seam (`FakeAudioFocus`, `AudioFocusContract`).
- Picture in picture: `PlayerBackend.pictureInPicture` (`PictureInPicture`,
  `NoPictureInPicture`), `PlayerPool.startPictureInPicture`,
  `stopPictureInPicture` and `pictureInPicture`; the window counts as a view
  of its player, and closing it pauses the player.
  `PictureInPictureContract` and `FakePictureInPicture` in `testing.dart`.
- `NativePlayerBackend` (`package:mpx_player/native.dart`): Media3 ExoPlayer
  on Android and AVPlayer on iOS and macOS, drawing into textures and
  reading bytes through `http_bytes_cache`'s native reader. Sources come
  from the host (`PlayerSource`, best first; `PlayerSource.hls` and `kind`
  on Android, with `playlists`); a codec that failed on the device is
  skipped. Players pause when the app is hidden unless `backgroundAudio`
  is set. `PlayerDevice` and `PlayerDecoder` probe the hardware and gate
  prepared players.
- `NativePlayerBackend.watchSource` (`PlayerSourceWatch`:
  `AssetOutsideReader? Function(RangedRequest source)`) is opened per source
  a player reads and closed when it lets the source go, so the bytes it
  pulls count as the content's download
  (`AssetCacheScope.openOutsideReader`).
- Buffering: a player that has not played yet buffers only
  `NativePlayerBackend.preparedBuffer` ahead (about 2 s and 2 MiB), lifted
  at its first play. Android starts on 100 ms of buffered media (1 s after
  a stall).
- Playhead: the platform players report every 100 ms while playing
  (`NativePlayerSnapshot.sampledAtUs`), and the playhead slews onto each
  report at the measured rate, smooth through speed changes; seeks, pauses,
  loop wraps and large errors move it at once. Android applies a speed
  change at once and lowers the pitch slightly above 1x.
- Failures: a failure says where it came from and the platform players log
  the whole error; a failed state keeps its error. A watchdog fails a
  player that reports playing but stops for
  `NativePlayerBackend.stallTimeout` (3 s). `PlayerDiagnostics` is an
  opt-in lifecycle log. Players mark their way from lease to first frame in
  the timeline and system trace (`mpx.player <stage> <id>`) outside release
  builds.
- `PlatformStillDecoder` (`native.dart`): a fallback video decoder that
  draws a clip's first frame with the platform, for codecs the software
  decoder cannot read; register it with
  `DecoderRegistry.registerFallback(MediaKind.video, ...)`. Every request
  is answered (also after dispose) within 20 s, two run at a time on
  Android. `PlatformStillBackend` is its seam; `FakePlatformStillBackend`
  is in `testing.dart`.
- Feed: `FeedController`, `FeedSlot` and `FeedScope` play a feed inside any
  host scrollable; slots measure their visible share against every
  enclosing viewport (again when first painted and when their route is back
  on top), and the controller plans per frame and exposes each item's
  `FeedItemState` (`clip`, `released` past
  `FeedPolicy.heavyUnloadViewports`). In pager mode the most visible page
  plays. `FeedActiveItemRule.pick`, `FeedListPlanner`, `FeedPagerPlanner`
  and `FeedPager` (`itemCount`, `replan`, `held`, `muted`); items whose
  facts are unknown are neither played nor warmed. An active item the
  autoplay gate holds back (`FeedAutoplay.none`) gets no player; one that
  held a player keeps it paused.
- `FeedPolicy` (`list` and `pager` defaults, `boundPreload`,
  `initialMute`, `pausingLayers`, `preloadBackOffLayers`), `FeedItem`
  (`descriptor`, `downloadContext`), `FeedConditions` (`silenced`) and
  `FeedSignals` (network, power saving, thermal state, ringer).

## 0.0.1

- Initial package skeleton.
