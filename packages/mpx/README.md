# mpx

The composition root of mpx: builds a media stack from the core and the bytes cache.

> Skeleton: the API lands with the tickets of the mpx build order. Nothing is
> usable yet.

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
```

## Features (planned)

- Media stack factory
- Fetch adapter over the bytes cache
- Device signals

## Docs

- [Spec](../../docs/spec.md)
- [Package topology (ADR 0001)](../../docs/adr/0001-package-topology.md)
