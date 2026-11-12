# mpx_core

The core of mpx: media identity, an asset cache and decode pipeline, playback clock, budgets and texture hosts.

> Skeleton: the API lands with the tickets of the mpx build order. Nothing is
> usable yet.

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
```

## Features (planned)

- Media keys and descriptors
- Asset cache and decode pipeline
- Platform texture hosts and the engine image decoder

## Docs

- [Spec](../../docs/spec.md)
- [Package topology (ADR 0001)](../../docs/adr/0001-package-topology.md)
- [ADR 0003](../../docs/adr/0003-media-core-and-decoders.md)
