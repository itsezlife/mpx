# Changelog

## Unreleased

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
