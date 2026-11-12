# mpx_ui

Optional media UI for mpx: a fullscreen media viewer and feed list and pager widgets.

> Early: the feed list works; the viewer and the pager are on their way.

## Install

Not published yet. Depend on it from git:

```yaml
dependencies:
  mpx_ui:
    git:
      url: https://github.com/itsezlife/mpx.git
      path: packages/mpx_ui
```

## Usage

```dart
import 'package:mpx_ui/mpx_ui.dart';

FeedListView(
  itemCount: clips.length,
  itemExtent: 240,
  itemOf: (i) => FeedItem(clips[i].key, byteSize: clips[i].size),
  presetOf: (i, profile) => AssetPresets.media(
    size: const Size(360, 240),
    devicePixelRatio: 3,
    profile: profile,
  ),
);
```

## Features

- `FeedListView`: every visible clip plays muted, frames advance above the
  policy's floor, the items ahead preload by stage

Planned: fullscreen viewer, feed pager.

## Docs

- [Spec](../../docs/spec.md)
- [Package topology (ADR 0001)](../../docs/adr/0001-package-topology.md)
- [ADR 0006](../../docs/adr/0006-viewer.md)
