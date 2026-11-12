# mpx_lottie

A vector animation decoder for mpx_core, backed by a native library built by a build hook.

> Skeleton: the API lands with the tickets of the mpx build order. Nothing is
> usable yet.

## Install

Not published yet. Depend on it from git:

```yaml
dependencies:
  mpx_lottie:
    git:
      url: https://github.com/itsezlife/mpx.git
      path: packages/mpx_lottie
```

## Usage

```dart
import 'package:mpx_lottie/mpx_lottie.dart';
```

## Features (planned)

- Vector animation decoder
- Frame cache

## Docs

- [Spec](../../docs/spec.md)
- [Package topology (ADR 0001)](../../docs/adr/0001-package-topology.md)
- [ADR 0003](../../docs/adr/0003-media-core-and-decoders.md)
