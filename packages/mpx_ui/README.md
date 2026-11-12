# mpx_ui

Optional media UI for mpx: a fullscreen media viewer and feed list and pager widgets.

> Early: the feed list and the photo viewer work; video in the viewer and
> the pager are on their way.

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

Open the viewer from a list:

```dart
MediaViewer.show(
  context,
  source: gallery, // your GallerySource
  initialIndex: 4,
  bridge: origins, // your OriginBridge: where each item sits on screen
  tokens: ViewerTokens(background: theme.colorScheme.scrim),
  chrome: ViewerChrome(
    title: (context, i, item) => Text(authorOf(i)),
    openFile: (key) async => leaseFromYourCache(key), // a ViewerFile
    actions: (i, item) => [
      ViewerAction(
        label: 'Save',
        onSelected: (request) async {
          final file = await request.file();
          if (file != null) await saveToGallery(file.path);
        },
      ),
    ],
  ),
);
```

## Features

- `FeedListView`: every visible clip plays muted, frames advance above the
  policy's floor, the items ahead preload by stage
- `MediaViewer`: photos open from and close to their origin; drag down to
  dismiss, double tap and pinch to zoom, swipe to page; `ViewerPolicy.$Android`
- Viewer chrome: bars, counter, caption, thumbnail strip and menu; save and
  share stay the host's actions, handed the cached file and the current frame

Planned: viewer video, iOS and desktop policies, feed pager.

## Docs

- [Spec](../../docs/spec.md)
- [Package topology (ADR 0001)](../../docs/adr/0001-package-topology.md)
- [ADR 0006](../../docs/adr/0006-viewer.md)
