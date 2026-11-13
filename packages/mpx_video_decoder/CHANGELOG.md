# Changelog

## Unreleased

- A silent clip reports its position and seeks to one
  (`playbackPosition`, `seekPlayback`, `VideoFrameLease.skipTo`), so a player
  can hand its position back to the loop.
- The software video decoder and its native library in one package, on
  `mpx_core`'s `MediaKey` and `MediaKind`.
- Native names renamed once: `libmpx_video`, `mpx_video_*` C symbols,
  `MpxVideo*` Dart types, and the `MPX_VIDEO_FFMPEG_DIR` environment
  variable.

## 0.0.1

- Initial package skeleton.
