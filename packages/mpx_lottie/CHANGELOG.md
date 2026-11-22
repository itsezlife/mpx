# Changelog

## Unreleased

- A prebuilt download is ended by a stall (no bytes for a minute), not by
  its length, so a slow link still gets the library. A whole fetch is
  capped at 15 minutes. Before this, a megabyte at about 10 KB/s timed out
  after 60 s, and the build fell back to cargo, or to no library at all on a
  machine without Rust.
- Prebuilt libraries are published (`native/prebuilts.json`). Android
  armeabi-v7a (`android-arm`) is a target, and the header check reads ELF32.
- `native/tool/build_prebuilts.dart` builds the libraries this host can, as
  the hook builds them.
- `LottieDecoder` releases its fetched content once it is read.
- The Lottie paintables say their picture size (`pictureSize`).
- `FrameCache.evict(bytes)`: frees files least recently used first, never one
  in use, so the folder registers as a store quota
  (`MpxStack.registeredQuotas`); `FrameCache.diskBytes` and `scan()` give the
  usage to report.
- The Lottie decoder and its native library in one package, on `mpx_core`'s
  `MediaKey` and `MediaKind`.
- Native names renamed once: `libmpx_lottie`, `mpx_lottie_*` C symbols,
  `MpxLottie*` Dart types, `mpx_lottie_worker.js` / `mpx_lottie_core.mjs`,
  and `MPX_LOTTIE_*` environment variables.

## 0.0.1

- Initial package skeleton.
