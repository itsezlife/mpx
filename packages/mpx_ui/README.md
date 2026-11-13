# mpx_ui

Optional media UI for mpx: a fullscreen media viewer and feed list and pager widgets.

> Early: the API may still change before the first release.

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
  policy: ViewerPolicy.$IOS, // or $Android, $Desktop
  players: pool, // a PlayerPool, for video items
  onFullscreenChanged: (on) => window.setFullscreen(on), // your window API
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
- `FeedPagerView`: the page shown plays with sound, its neighbours keep
  prepared players, a swipe takes one over
- `MediaViewer`: photos and videos open from and close to their origin;
  dismiss drag, zoom and paging per `ViewerPolicy.$Android`, `$IOS` or
  `$Desktop` (an in-app overlay with keyboard, wheel and step zoom)
- Viewer video on the player pool: seek bar with preview, double-tap seek,
  auto-hide, speed (kept per item, per viewer or per session), quality,
  hold to play faster, the loop rule; GIFs loop muted without controls
- Viewer chrome: bars, counter, caption, thumbnail strip and menu; save and
  share stay the host's actions, handed the cached file and the current frame

## Docs

- [Spec](../../docs/spec.md)
- [Package topology (ADR 0001)](../../docs/adr/0001-package-topology.md)
- [ADR 0006](../../docs/adr/0006-viewer.md)
