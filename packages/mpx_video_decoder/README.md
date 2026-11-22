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

The build hook bundles a small C wrapper (`libmpx_video`) and the FFmpeg
libraries it links. Nothing needs building: see "Native library delivery"
below.

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

## Native library delivery

The hook takes the first of these that is there:

1. **Your own FFmpeg build** (for working on the decoder). Build it with the
   recipe (`TARGET=<target> native/recipe/build.sh`; targets `macos-arm64`,
   `macos-x64`, `ios-arm64`, `ios-sim-arm64`, `android-arm64`, `android-arm`,
   `android-x64`) and name the recipe's build directory in the app's pubspec
   (the workspace root's, in a pub workspace). A relative path is read from
   that pubspec's folder:

   ```yaml
   hooks:
     user_defines:
       mpx_video_decoder:
         ffmpeg_build: ../mpx/packages/mpx_video_decoder/native/.build
   ```

2. **The prebuilt** named in `native/prebuilts.json`: release files of this
   repository, pinned by size and SHA-256 and by the hash of the sources
   they were built from (the wrapper and the recipe). The hook downloads
   each file once into its shared cache and checks it before use. A
   prebuilt for other sources (a changed wrapper or recipe) is not used.
3. **A recipe build in the package itself** (`native/.build/<target>`, as in
   a checkout of this repository), or `MPX_VIDEO_FFMPEG_DIR` where the hook
   sees the environment. The Flutter tool's hook runner passes a hook only
   `PATH`, `HOME` and the NDK's variables, which is why (1) is a user define.

With none, the build succeeds and warns, and `NativeVideoBinding.probe()`
reports `missingLibrary`: video has no decoder and keeps its placeholder.

Prebuilt targets: macOS arm64 and x86_64; iOS arm64 (device and
Apple-silicon simulator); Android arm64-v8a, armeabi-v7a and x86_64. The
x86_64 builds are plain C (no assembly) and decode more slowly. The iOS
x86_64 simulator, Linux and Windows have none.

**Offline and CI.** The first build of a target downloads its files (about
3.5 MB) from GitHub. Later builds, and every other app on the machine, use
the shared cache. A CI cache of the Flutter tool's build directory keeps it
offline after the first run. Without network and without a cache, name an
FFmpeg build as in (1).

### Licensing

The FFmpeg libraries are LGPL 2.1 or later, built as shared libraries
from the unmodified FFmpeg 9.0.2. The configure lines enable no GPL,
nonfree or version-3 component, and the recipe refuses one. libvpx (BSD-3,
with the WebM patent grant) is linked into libavcodec. The release beside
the libraries holds the exact sources, the configure line of every target,
the recipe and the toolchain versions, so the libraries can be rebuilt and
replaced.

An app that ships them takes on the LGPL's duties. It must say that it uses
FFmpeg under the LGPL (an about screen or the store notes) and include the
licence text. It must also let users replace the libraries: they are shared
libraries, bundled as separate files.

## Docs

- [Spec](../../docs/spec.md)
- [Media core and decoders (ADR 0003)](../../docs/adr/0003-media-core-and-decoders.md)
