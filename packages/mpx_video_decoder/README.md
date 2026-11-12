# mpx_video_decoder

A software video decoder for mpx_core that plays short silent loops through a native library.

> Skeleton: the API lands with the tickets of the mpx build order. Nothing is
> usable yet.

## Install

Not published yet. Depend on it from git:

```yaml
dependencies:
  mpx_video_decoder:
    git:
      url: https://github.com/itsezlife/mpx.git
      path: packages/mpx_video_decoder
```

## Usage

```dart
import 'package:mpx_video_decoder/mpx_video_decoder.dart';
```

## Features (planned)

- Silent loop decoding
- Decode-only native library

## Docs

- [Spec](../../docs/spec.md)
- [Package topology (ADR 0001)](../../docs/adr/0001-package-topology.md)
- [ADR 0003](../../docs/adr/0003-media-core-and-decoders.md)
