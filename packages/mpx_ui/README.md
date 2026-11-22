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

## Library grid

A grid over a `mpx_library` album with an ordered selection; it hands the
host the selection and knows nothing of what it becomes:

```dart
final selection = OrderedPickerSelection(cap: 10);
LibraryGrid(
  library: library,                 // a MediaLibrary
  album: albums.first,              // the all-media album
  selection: selection,
  policy: LibraryGridPolicy.forPlatform(defaultTargetPlatform),
  labels: const LibraryGridLabels(
    photo: 'Photo', video: 'Video', open: 'Open', select: 'Select',
    gif: 'GIF',
  ),
  onOpen: (asset, index) => openViewer(index),
  onRefused: (key, reason) => showLimit(reason),
  cameraSlotBuilder: (context, signals) => MyCameraPreview(signals),
);
```

- Fixed square cells, never measured; thumbnails through `AssetView`
  under the host's `AssetCacheProvider`, a thumbnail key per cell pixel
  size; pages load around the viewport with one screen of prefetch.
- Numbered checks; a tap on the check toggles, a tap on the picture opens.
  Swipe select: a long press and a drag (`$Android`), or a horizontal pan
  from x > 44 that fails on 5 pt of vertical movement before 8 pt of
  horizontal (`$IOS`); the first cell's new state goes to every cell
  crossed, and the grid scrolls by itself at its edges.
- A refused toggle (the cap, the host's gate) goes to `onRefused`.
- The camera slot, one column by two rows at the leading top of the
  all-media album, is the host's: `mpx_ui` takes no edge to `mpx_capture`.
  `CameraSlotSignals.shouldPause` says when its preview should pause.
- Library changes re-read the pages and keep the selection; `$Android`
  holds them while `viewerOpen`.

`LibraryPicker` puts it together: the album switcher (a drop-down of
covers, names and counts on `$Android`, a menu from the title on `$IOS`),
the grid in every library access state (a Manage banner for iOS's limited
access, a banner that asks again for Android 14's partial access, the
denied and restricted states, an empty album, media not allowed), and the
picker-mode viewer (`PickerViewer`): the fullscreen viewer over the album
with a check through the same selection, a counter that shows the selected
items, and a bottom slot the host fills (`viewerBottomBuilder`; with
nothing checked its `keys` are the item shown).

## Docs

- [Spec](../../docs/spec.md)
- [Package topology (ADR 0001)](../../docs/adr/0001-package-topology.md)
- [ADR 0006](../../docs/adr/0006-viewer.md)
- [Library, intake, preparation and picking (ADR 0011)](../../docs/adr/0011-library-and-picking.md)
