# mpx_player

A hardware video player for mpx: a player pool with leases, one audio owner, and feed playback modes.

> Early: the pool, leases and views work over a fake backend; the Media3 and
> AVPlayer backends land next.

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

final pool = PlayerPool(backend: backend);
final lease = pool.lease(const MediaKey.remote('42'))..play();
// In the tree: PlayerView(lease: lease, standIn: thumbnail)
lease.release();
```

## Features

- Player pool keyed by `MediaKey`; leases share one player, so hand-offs
  keep position and buffer
- One immutable `PlayerState` per player; the playhead is read per frame
- `PlayerBudget` of playing and prepared engines, coldest released first
- `PlayerView` with a stand-in until the first frame
- `FakePlayerBackend` and `PlayerEngineContract` in `testing.dart`
- `FeedPolicy`: the 25 feed knobs with reference defaults per mode;
  `FeedListPlanner` decides what a list plays, shows in view and preloads

Planned: Media3 and AVPlayer backends, one audio owner, the pager mode.

## Docs

- [Spec](../../docs/spec.md)
- [Package topology (ADR 0001)](../../docs/adr/0001-package-topology.md)
- [ADR 0004](../../docs/adr/0004-player.md)
