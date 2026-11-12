# mpx

The composition root of mpx: builds a media stack from the core and the bytes cache.

> Early: device signals work; the stack and the fetch adapter land with later
> tickets of the mpx build order.

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

final signals = DeviceSignals();
signals.network.addListener(() => print(signals.network.value));
// ...
signals.dispose();
```

Tests take `FakeDeviceSignals` from `package:mpx/testing.dart`.

## Features

- Device signals (Android, iOS, macOS): network class (none, unmetered,
  metered, roaming), power-saving mode and thermal status as
  `ValueListenable`s. Run [example/](example/) to watch them change.

Planned: media stack factory, fetch adapter over the bytes cache.

## Docs

- [Spec](../../docs/spec.md)
- [Package topology (ADR 0001)](../../docs/adr/0001-package-topology.md)
