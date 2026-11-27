# mpx_core

Media core for Flutter: media keys, an asset cache with a fetch and decode
pipeline, a playback clock, budgets and platform texture hosts.

## Install

Not published yet. Depend on it from git:

```yaml
dependencies:
  mpx_core:
    git:
      url: https://github.com/itsezlife/mpx.git
      path: packages/mpx_core
```

## Usage

```dart
import 'package:mpx_core/mpx_core.dart';

final decoders = DecoderRegistry()
  ..register(MediaKind.still, const ImageCodecDecoder())
  ..register(MediaKind.animatedImage, const ImageCodecDecoder());
final pipeline = AssetPipeline(fetcher: myFetcher, decoders: decoders);
final scope = AssetCacheScope(producer: pipeline);

pipeline.know(
  const MediaDescriptor(key: MediaKey.remote('42'), kind: MediaKind.still),
);

// In the widget tree:
AssetCacheProvider(
  scope: scope,
  child: AssetView(
    content: const MediaKey.remote('42'),
    preset: AssetPresets.square(
      extent: 64,
      devicePixelRatio: 2,
      profile: const AssetProfile(),
    ),
  ),
);
```

`myFetcher` is the host's `ContentFetcher`; the `mpx` package fills it from
`http_bytes_cache`.

## Features

- `MediaKey` and `MediaDescriptor`: media identity, never a URL.
- `AssetCacheScope`: staged readiness, byte-budgeted LRU, sibling stages.
- `AssetPipeline`: resolve, fetch and decode with priority lanes and
  cancellation.
- `PlaybackClock` with pause layers, fps caps and background holds.
- Feed inputs: visible fraction with an advance floor, staged preloads
  (metadata, a prefix in seconds, first frame) ordered by distance, network
  and thermal inputs that hold preloads back.
- Frame pool (`frame_pool.dart`) and platform texture hosts on Android, iOS
  and macOS.
- `ImageCodecDecoder` for the engine's image formats, stills and animated
  WebP / GIF.
- Core seams between optional packages: `TrackedTransfers` (tracked
  downloads and uploads per key, `ContentFileLease`), which an
  `AssetCacheScope` takes for the downloads of surfaces with a status
  control, and `MediaPreparation` with its values (`PreparationInput`,
  `PreparationIntent`, `CompressionPreset`, `PreparedMedia`) and their
  stored form, `PreparationEncoding`.
- Diagnostics events through `MpxDiagnostics.current`.
- Fakes and contract suites in `testing.dart`.

## Docs

- [Spec](../../docs/spec.md)
- [Package topology (ADR 0001)](../../docs/adr/0001-package-topology.md)
- [Media core and decoders (ADR 0003)](../../docs/adr/0003-media-core-and-decoders.md)
