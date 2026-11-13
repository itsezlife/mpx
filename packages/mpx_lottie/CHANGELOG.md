# Changelog

## Unreleased

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
