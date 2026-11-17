# Changelog

## Unreleased

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
