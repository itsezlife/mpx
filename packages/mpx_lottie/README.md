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

The build hook bundles the native library (`libmpx_lottie`). It
downloads the prebuilt named in `native/prebuilts.json`, a release file of
this repository pinned by size, SHA-256 and the hash of the crate's sources.
It downloads it once into its shared cache and checks it before use.

- **Prebuilt targets:** macOS arm64 and x86_64; iOS arm64 and the arm64 and
  x86_64 simulators; Android arm64-v8a, armeabi-v7a and x86_64.
- **From source.** Elsewhere, for changed crate sources, or with the
  `build_from_source` user define (`MPX_LOTTIE_BUILD_FROM_SOURCE=1`), it
  compiles `native/` with cargo instead. Install Rust from
  [rustup.rs](https://rustup.rs) and add the target (`rustup target add
  ...`); Android needs the NDK, iOS and macOS a Mac.
- **Nothing.** Without either, the build succeeds and
  `NativeLottieBinding.probe()` reports the library as missing.
- **Offline.** The first build of a target needs network for the prebuilt;
  later builds use the cache.
- **Building prebuilts.** `dart native/tool/build_prebuilts.dart <dir>`
  builds every key this host can; `native/tool/assemble_manifest.dart` writes
  the manifest.

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

With `MpxStack`, the cache's folder can count against the store's one budget
as the `lottie_frames` quota, instead of a budget or sweep of its own:

```dart
final frames = FrameCache(directoryPath: framesDir, diskBudgetBytes: null);
final stack = await MpxStack.create(
  // ...
  registeredQuotas: {BytesQuota.lottieFrames: frames.evict},
  decoders: (context) async {
    final quota = context.registeredQuotas[BytesQuota.lottieFrames.name]!;
    frames.diskBytes.addListener(
      () => quota.reportUsage(frames.diskBytes.value),
    );
    await frames.scan();
    // ... the Lottie decoder over `frames`
  },
);
```

## Features

- Render isolates (or a web worker) drawing straight into frame pool pages or
  platform textures.
- An on-disk frame cache (lz4) keyed by file hash, size and engine version;
  its folder can be a quota of the host's store (`FrameCache.evict`,
  `diskBytes`).
- Build hook: compile from source, or a hash-pinned prebuilt
  (`native/prebuilts.json`); force a source build with the
  `build_from_source` user define or `MPX_LOTTIE_BUILD_FROM_SOURCE=1`.
- Native names: `libmpx_lottie`, C symbols `mpx_lottie_*`, worker
  `mpx_lottie_worker.js`.
- Fakes and contract suites in `testing.dart`.

## Docs

- [Spec](../../docs/spec.md)
- [Media core and decoders (ADR 0003)](../../docs/adr/0003-media-core-and-decoders.md)
