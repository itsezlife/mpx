# Changelog

## Unreleased

- A clip whose container turns it (a phone's portrait recording: a display
  matrix of a quarter turn) decodes as shown: the info gives the turned
  size and every frame comes turned. Such a clip showed sideways.
- A clip larger than the software path decodes (past 3840 a side, an 8K
  recording) fails as `DecodeFailure.unsupported`, like a codec the build
  lacks: the host's fallback (the platform's still) draws it instead of
  nothing.
- A prebuilt file whose download fails is tried three times before the
  hook gives up. The hook's result is cached, so one flaky answer used to
  leave a build without video until `flutter clean`. The warning now says
  so.
- Prebuilt libraries: the hook downloads the wrapper and FFmpeg for its
  target from this repository's releases (`native/prebuilts.json`, pinned by
  size, SHA-256 and the hash of the sources), into its shared cache. An app
  needs no FFmpeg build of its own. The order is: an FFmpeg build the app
  names (user define), then the prebuilt, then a recipe build in the
  package.
- More targets: macOS x86_64, Android armeabi-v7a and Android x86_64 (the
  x86_64 builds are plain C, with no assembly).
- The hook finds FFmpeg through the app's pubspec, as
  `hooks: user_defines: mpx_video_decoder: ffmpeg_build: <dir>` (laid out as
  the recipe's `.build`). Before this, an app that took the package from git
  bundled no video library: its checkout has no recipe build, and the hook
  runner never passes `MPX_VIDEO_FFMPEG_DIR`. So every video stayed at its
  placeholder, with only a build warning to show for it.
- A clip this build cannot play (`VideoRejection.unsupported`) fails with
  `DecodeFailure.unsupported` (its cause the `VideoDecodeRejected`), so the
  pipeline tries the host's fallback for video; other rejections are
  unchanged.
- A clip whose decodes cannot keep up with its frame rate no longer plays
  in ever slower motion: when its newest frame falls more than
  `VideoFrameScheduler.catchUpLag` (1 s) behind its clock it seeks to the
  clock and goes on from there. `VideoFrameLease.lag` says how far behind
  it is.
- A clip read through a ranged source never waits for bytes: the wrapper
  asks the reader what is there (`reader_available`) and answers
  `MPX_VIDEO_STALLED` (`VideoRejection.stalled`, `VideoFrameStatus.stalled`)
  instead of blocking its worker. It starts no packet without
  `lookaheadBytes` past its position, and when a packet was cut short it
  goes back to the frame after the last one returned. The scheduler keeps a
  stalled clip's frame and clock and gives its turn up until
  `VideoFrameLease.wake` (the source's `landed` signal) or `stallRetry`; the
  decoder retries a stalled open or first frame on the same signal; a
  paintable that leaves the screen pauses its source's fetching. Ranged
  reader table version 3.
- `VideoFrameScheduler.logPlayback`: every playing clip logs frames decoded
  and shown every two seconds, for a clip that does not move on a device.
- Breaking: `VideoBinding.open` and `VideoEngine.open` take a `VideoSource`:
  bytes, a file path, or a ranged resource of the bytes cache's native
  reader. A file or ranged source is read in place by the decode worker, at
  the offsets the demuxer asks for, so a clip's bytes no longer pass through
  the UI isolate; a ranged source opens once its head has landed and blocks
  the worker for missing bytes. `VideoDecoder` opens `FetchedFile` and
  `FetchedRanged` content that way and releases it when its clip closes.
- ABI version 3: `mpx_video_open_file`, `mpx_video_open_reader` and the
  status `MPX_VIDEO_SOURCE_FAILED` (`VideoRejection.source`).
- A clip read in place costs its frame only; the encoded size counts for
  bytes held in memory.
- `VideoDecoder.logFailures`: each stage of a decode (decode, opened, first
  frame, still) and the reason a decode failed go to the log as `mpx_video:`
  lines, so a clip left on its placeholder can be told apart on a device.
- A file or a ranged resource has no byte cap (`MPX_VIDEO_TOO_LARGE` is the
  in-memory open's only): it is read in place, so clips over 10 MiB (most
  1080p and 4K clips, every long trailer) no longer stay on their
  placeholder.
- Seek to a time: `mpx_video_seek` (ABI version 2) goes back to the keyframe
  before it and decodes forward on the engine's side, through
  `VideoBinding.seek`, `VideoEngine.seek` and `VideoFrameLease.seekTo`. A
  silent clip reports its position and seeks to one (`playbackPosition`,
  `seekPlayback`), showing the picture it is handed until its frame there is
  drawn, so a player can hand its position back to the loop.
- The video paintables say their picture size (`pictureSize`).
- `native/recipe/build.sh` runs under the macOS system bash.
- The software video decoder and its native library in one package, on
  `mpx_core`'s `MediaKey` and `MediaKind`.
- Native names renamed once: `libmpx_video`, `mpx_video_*` C symbols,
  `MpxVideo*` Dart types, and the `MPX_VIDEO_FFMPEG_DIR` environment
  variable.

## 0.0.1

- Initial package skeleton.
