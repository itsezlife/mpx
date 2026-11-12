# mpx

The composition root of mpx: one call builds a media stack from the core and
the bytes cache, with the decoders the host passes in.

## The set

```
optional   mpx_ui           mpx_capture
              |                  |
           mpx_player       mpx_lottie   mpx_video_decoder       mpx
              |                  |              |                  |
base       mpx_core      http_bytes_cache   (never depend on each other)
```

| Package | What it is | Depends on |
| --- | --- | --- |
| `http_bytes_cache` | HTTP bytes cache: one disk store, quotas, priorities, ranged resources | - |
| `mpx_core` | Media identity, asset cache, fetch and decode pipeline, clock, textures, image codecs | - |
| `mpx_lottie` | Lottie decoder with a native renderer | `mpx_core` |
| `mpx_video_decoder` | Silent video loops with a native decoder | `mpx_core` |
| `mpx_player` | Player pool, sound owner, feed modes | `mpx_core`, `http_bytes_cache` |
| `mpx_ui` | Optional viewer and feed widgets | `mpx_player`, `mpx_core` |
| `mpx_capture` | Optional compression and round video | `mpx_core`, `http_bytes_cache` |
| `mpx` | `MpxStack`, the fetch adapter, device signals | `mpx_core`, `http_bytes_cache` |

`mpx` has no edge to the decoders, the player, the UI or capture, so taking it
links no FFmpeg, Media3 or camera code. No package re-exports another: import
the packages whose types you use.

## Install

Not published yet. Depend on it from git:

```yaml
dependencies:
  mpx:
    git:
      url: https://github.com/itsezlife/mpx.git
      path: packages/mpx
```

## Usage

```dart
import 'package:mpx/mpx.dart';
import 'package:mpx_core/mpx_core.dart';

final stack = await MpxStack.create(
  // Where the bytes of a key are; asked only for media the cache lacks.
  locate: (descriptor, part) =>
      MediaLocation('https://cdn.example/${descriptor.key.encoded}'),
  cacheDirectory: '/path/to/cache/media',
  // Optional: decoders from mpx_lottie or mpx_video_decoder, built over the
  // stack's clock and textures.
  decoders: (context) async => {},
);

runApp(
  AssetCacheProvider(
    scope: stack.scope,
    child: ContentView(content: const MediaKey.remote('42'), preset: preset),
  ),
);
// ...
await stack.dispose();
```

A host with its own wiring takes the fetch adapter alone:
`BytesCacheFetcher(store: store, client: client, locate: locate)` fills
`mpx_core`'s `ContentFetcher`.

## Features

- `MpxStack.create`: bytes store, HTTP client (retry, timeout, conditional),
  fetch adapter, pipeline and asset cache scope; stills and animated images
  through the engine codecs; host decoders; folders other owners keep
  registered as store quotas; device signals and the app lifecycle driving the
  pause layers. `dispose` releases what it created.
- `BytesCacheFetcher`: media keyed in the cache by `MediaKey`, never by URL;
  held media served without a lookup or a request; one download shared by
  every caller, each hearing its progress; cancel settles at once; priorities
  onto the client's queue; failures classed transient or permanent; media never
  revalidated unless its location asks.
- Device signals (Android, iOS, macOS): network class, power saving and
  thermal status as `ValueListenable`s.
- Fakes and contract suites in `testing.dart`.

[example/](example/) draws a still, an animated WebP, a Lottie and a video
loop through one stack.

## Docs

- [Spec](../../docs/spec.md)
- [Package topology (ADR 0001)](../../docs/adr/0001-package-topology.md)
- [Bytes cache (ADR 0002)](../../docs/adr/0002-bytes-cache.md)
