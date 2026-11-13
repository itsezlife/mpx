# Changelog

## Unreleased

- Seek to a time: `mpx_video_seek` (ABI version 2) goes back to the keyframe
  before it and decodes forward on the engine's side, through
  `VideoBinding.seek`, `VideoEngine.seek` and `VideoFrameLease.seekTo`. A
  silent clip reports its position and seeks to one (`playbackPosition`,
  `seekPlayback`), showing the picture it is handed until its frame there is
  drawn, so a player can hand its position back to the loop.
- `native/recipe/build.sh` runs under the macOS system bash.
- The software video decoder and its native library in one package, on
  `mpx_core`'s `MediaKey` and `MediaKind`.
- Native names renamed once: `libmpx_video`, `mpx_video_*` C symbols,
  `MpxVideo*` Dart types, and the `MPX_VIDEO_FFMPEG_DIR` environment
  variable.

## 0.0.1

- Initial package skeleton.
