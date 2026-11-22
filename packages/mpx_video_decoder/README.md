# mpx_video_decoder

A software video decoder for `mpx_core` that plays silent clips through an
FFmpeg and libvpx library delivered by a build hook.

## Install

Not published yet. Depend on it from git:

```yaml
dependencies:
  mpx_video_decoder:
    git:
      url: https://github.com/itsezlife/mpx.git
      path: packages/mpx_video_decoder
```

The hook compiles a small C wrapper against an FFmpeg + libvpx prefix and
bundles the FFmpeg libraries. Build the prefix once per target with
`native/recipe/build.sh` (`TARGET=ios-arm64` or `android-arm64`; macOS arm64
by default). It lands in the recipe's `native/.build/<target>/prefix`.

An app that takes this package from git builds against a checkout that has
no such directory, and the hook runner passes a hook none of your
environment but `PATH`, `HOME` and the NDK's variables. So name the recipe's
build directory in the app's pubspec (the workspace root's, in a pub
workspace); a relative path is read from that pubspec's folder:

```yaml
hooks:
  user_defines:
    mpx_video_decoder:
      ffmpeg_build: ../mpx/packages/mpx_video_decoder/native/.build
```

`MPX_VIDEO_FFMPEG_DIR` (one prefix) still works where the hook sees the
environment. Without a prefix the build still succeeds, warns, and
`NativeVideoBinding.probe()` reports the library as missing: video then has
no decoder and its content keeps its placeholder.

## Usage

```dart
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_video_decoder/mpx_video_decoder.dart';

try {
  final engine = await IsolateVideoEngine.spawn(); // throws when unavailable
  final scheduler = VideoFrameScheduler(
    engine: engine,
    atlas: VideoFrameAtlas.create(),
    clock: scope.clock,
  );
  decoders.register(
    MediaKind.video,
    VideoDecoder(engine: engine, scheduler: scheduler),
  );
} on Object catch (reason) {
  // No decoder: video keeps its placeholder.
}
```

At shutdown dispose the scheduler, then the engine.

## Features

- Decode-only, for short silent loops: a pool of worker isolates, frames into
  frame pool pages or platform textures; a `<video>` element on the web.
- Clips are read in place, from a file or through the bytes cache's native
  ranged reader as they download: the UI isolate never holds their bytes.
- macOS arm64, iOS arm64 and Android arm64-v8a.
- Native names: `libmpx_video`, C symbols `mpx_video_*`.
- Fakes and contract suites in `testing.dart`.

## Docs

- [Spec](../../docs/spec.md)
- [Media core and decoders (ADR 0003)](../../docs/adr/0003-media-core-and-decoders.md)
