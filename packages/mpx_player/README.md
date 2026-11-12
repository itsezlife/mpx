# mpx_player

A hardware video player for mpx: a player pool with leases, one audio owner, and feed playback modes.

> Skeleton: the API lands with the tickets of the mpx build order. Nothing is
> usable yet.

## Install

Not published yet. Depend on it from git:

```yaml
dependencies:
  mpx_player:
    git:
      url: https://github.com/itsezlife/mpx.git
      path: packages/mpx_player
```

## Usage

```dart
import 'package:mpx_player/mpx_player.dart';
```

## Features (planned)

- Player pool and leases
- One audio owner app-wide
- Feed list and pager modes

## Docs

- [Spec](../../docs/spec.md)
- [Package topology (ADR 0001)](../../docs/adr/0001-package-topology.md)
- [ADR 0004](../../docs/adr/0004-player.md)
