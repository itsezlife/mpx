# mpx_capture

Optional media capture for mpx: compression before send and round video recording.

> Skeleton: the API lands with the tickets of the mpx build order. Nothing is
> usable yet.

## Install

Not published yet. Depend on it from git:

```yaml
dependencies:
  mpx_capture:
    git:
      url: https://github.com/itsezlife/mpx.git
      path: packages/mpx_capture
```

## Usage

```dart
import 'package:mpx_capture/mpx_capture.dart';
```

## Features (planned)

- Compression before send
- Round video recording

## Docs

- [Spec](../../docs/spec.md)
- [Package topology (ADR 0001)](../../docs/adr/0001-package-topology.md)
- [ADR 0007](../../docs/adr/0007-capture.md)
