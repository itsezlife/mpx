# mpx_lottie

A Lottie decoder for `mpx_core` that renders vector animations with a native
Rust library (over tlottie) delivered by a build hook.

## Install

Not published yet. Depend on it from git:

```yaml
dependencies:
  mpx_lottie:
    git:
      url: https://github.com/itsezlife/mpx.git
      path: packages/mpx_lottie
```

No prebuilt library is published yet, so the hook compiles `native/` with
cargo: install Rust from [rustup.rs](https://rustup.rs) and add the targets
you build for (`rustup target add aarch64-apple-darwin aarch64-linux-android
...`). Android needs the NDK; iOS and macOS need a Mac. Without cargo the
build still succeeds, and `NativeLottieBinding.probe()` reports the library
as missing.

## Usage

Spawn the engine and register the decoder only when it starts:

```dart
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_lottie/mpx_lottie.dart';

try {
  final engine = await IsolateLottieEngine.spawn(); // throws when unavailable
  final scheduler = LottieFrameScheduler(atlas: atlas, clock: scope.clock);
  decoders.register(
    MediaKind.vectorAnimation,
    LottieDecoder(engine: engine, scheduler: scheduler, cache: frameCache),
  );
} on Object catch (reason) {
  // No decoder: vector animations keep their placeholder.
}
```

`atlas` is a `FrameAtlas` over a `LottieFrameRenderer` and one
`NativeFramePageMemory`; `frameCache` is an optional on-disk `FrameCache`. At
shutdown dispose the scheduler, then the cache, then close the engine.

## Features

- Render isolates (or a web worker) drawing straight into frame pool pages or
  platform textures.
- An on-disk frame cache (lz4) keyed by file hash, size and engine version.
- Build hook: compile from source, or a hash-pinned prebuilt
  (`native/prebuilts.json`); force a source build with the
  `build_from_source` user define or `MPX_LOTTIE_BUILD_FROM_SOURCE=1`.
- Native names: `libmpx_lottie`, C symbols `mpx_lottie_*`, worker
  `mpx_lottie_worker.js`.
- Fakes and contract suites in `testing.dart`.

## Docs

- [Spec](../../docs/spec.md)
- [Media core and decoders (ADR 0003)](../../docs/adr/0003-media-core-and-decoders.md)
