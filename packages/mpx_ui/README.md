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

In your own scrollable, wrap each cell in a `FeedSlot` with a `FeedClip`:

```dart
final feed = FeedController(presetOf: (i, profile) => presetFor(i, profile));

FeedScope(
  controller: feed,
  child: CustomScrollView(
    slivers: [
      SliverList.builder(
        itemCount: clips.length,
        itemBuilder: (context, i) => FeedSlot(
          index: i,
          item: FeedItem(clips[i].key),
          child: const FeedClip(),
        ),
      ),
    ],
  ),
);
```

Open the viewer from a grid thumbnail: mark each with a `ViewerOrigin`
under a `ViewerOriginScope`, and the viewer opens from and closes back to
it, clipped by the grid, with no bridge to write:

```dart
ViewerOriginScope(
  child: GridView.builder(
    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: 3,
    ),
    itemCount: gallery.count, // your GallerySource
    itemBuilder: (context, i) => GestureDetector(
      onTap: () => MediaViewer.show(context, source: gallery, initialIndex: i),
      child: ViewerOrigin(index: i, child: MyThumbnail(i)),
    ),
  ),
);
```

`MediaViewer.show` also takes a `ViewerController`, `players` (a
`PlayerPool`) for videos, `chrome` (bars, caption, host actions such as save
and share) and a `policy` (`ViewerPolicy.$Android`, `$IOS`, `$Desktop`; the
theme's platform's by default). `ViewerPhotoPage` and `ViewerVideoPage` work
alone inside a host's own pager, or as pages of a `GalleryPager`, the
viewer's own pager, which any host can use:

```dart
GalleryPager(
  count: items.length,
  physics: GalleryPagerPhysics.$Android,
  transition: const GalleryPageTransition.stack(),
  gap: 15,
  dismiss: ViewerPolicy.$Android.dismissClaim,
  onDismissEnd: (offset, velocity) => close(),
  pageBuilder: (context, index) => ViewerPhotoPage(
    policy: ViewerPolicy.$Android,
    child: MyPicture(items[index]),
  ),
)
```

## Configuring the viewer

Every behaviour is a field of `ViewerPolicy`; what a host does not set stays
the platform's. A `ViewerPolicyScope` above the viewers changes the
platform's policy (`copyWith` on the policy and each value in it), or
replaces it with `(_) => mine`:

```dart
ViewerPolicyScope(
  policy: (platform) => platform.copyWith(
    video: platform.video.copyWith(start: ViewerVideoStart.origin),
  ),
  child: app,
)
```

A `policy` passed to `MediaViewer.show` wins over the scope. A saved place
in a video is the host's: `videoStartOf` gives one, `onVideoLeft` reports
where the viewer left it.

## Features

- `FeedListView`: every visible clip plays muted, frames advance above the
  policy's floor, the items ahead preload by stage; items of any extent
- `FeedClip`: a slot's media in any host scrollable, on the cache or the
  player
- `FeedPagerView`: the page shown plays with sound, its neighbours keep
  prepared players, a swipe takes one over
- `ViewerOrigin`: thumbnails in any list become the viewer's origins
- `MediaViewer`: photos and videos open from and close to their origin;
  dismiss drag, zoom and paging per `ViewerPolicy.$Android`, `$IOS` or
  `$Desktop` (an in-app overlay with keyboard, wheel, trackpad, side strips
  and step zoom)
- `GalleryPager`: one gesture owner decides once, from the down point,
  between a pinch, a pan of a zoomed picture (handed on to the next page at
  its edge), a dismiss drag and a page drag; per-platform physics, tap
  timings, stacked, strip or instant pages, keep-alive, RTL order and
  semantics actions
- Viewer video on the player pool: seek bar with preview, double-tap seek,
  auto-hide, speed (kept per item, per viewer or per session), quality,
  hold to play faster, the loop rule; GIFs loop muted without controls
- Viewer chrome: bars, counter, caption, thumbnail strip and menu; save and
  share stay the host's actions, handed the cached file and the current frame

## Docs

- [Spec](../../docs/spec.md)
- [Package topology (ADR 0001)](../../docs/adr/0001-package-topology.md)
- [ADR 0006](../../docs/adr/0006-viewer.md)
