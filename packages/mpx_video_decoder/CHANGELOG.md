# Changelog

## Unreleased

- A silent clip takes the playback phase its content shares, so it shows the
  same frame as the same clip drawn at another size (`VideoFrameLease.skipTo`).
- The software video decoder and its native library in one package, on
  `mpx_core`'s `MediaKey` and `MediaKind`.
- Native names renamed once: `libmpx_video`, `mpx_video_*` C symbols,
  `MpxVideo*` Dart types, and the `MPX_VIDEO_FFMPEG_DIR` environment
  variable.

## 0.0.1

- Initial package skeleton.
