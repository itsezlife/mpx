# mpx_player

A hardware video player for mpx on Media3 and AVPlayer: a player pool with leases, one audio owner, picture in picture and feed playback modes.

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
import 'package:http_bytes_cache/native_reader.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_player/native.dart';

final backend = NativePlayerBackend(
  readers: NativeRangedReaders(RangedBytes(store: store, client: client)),
  sourcesOf: (key) => [
    PlayerSource(
      RangedRequest(url: urlOf(key), cacheKey: BytesCacheKey('ranged-${key.encoded}')),
    ),
  ],
);
final pool = PlayerPool(
  backend: backend,
  budget: (await backend.device).budget,
);
final lease = pool.lease(const MediaKey.remote('42'))..play();
// In the tree: PlayerView(lease: lease, standIn: thumbnail)
lease.release();
```

An HLS source lists before its MP4 fallback:
`PlayerSource.hls(RangedRequest(url: playlistUrl, cacheKey: streamKey))`.
Android plays it through the same cache: playlists are resolved through
`playlists` (an `IBytesResolver` over the store the readers serve) and
revalidated by HTTP rules, segments are read natively, each keyed by its
URL under the stream's key. Apple players skip it for the next source.

Tests use `FakePlayerBackend` from `testing.dart` instead.

### Platform setup

- Apple plays progressive MP4 and QuickTime (no WebM, no HLS yet).
  Android also plays WebM, Matroska and HLS.
  Background audio needs the `audio` background mode in `Info.plist`.
- Android picture in picture needs
  `android:supportsPictureInPicture="true"` on the activity. Background
  audio needs the service declared in the app's manifest:

```xml
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK" />
<service
    android:name="dev.mpx.player.MpxPlaybackService"
    android:foregroundServiceType="mediaPlayback"
    android:exported="true">
  <intent-filter>
    <action android:name="androidx.media3.session.MediaSessionService" />
  </intent-filter>
</service>
```

### A feed in your own list

Wrap each cell in a `FeedSlot`; the controller decides from what shows.

```dart
final feed = FeedController(itemCount: items.length, itemOf: (i) => items[i]);

FeedScope(
  controller: feed,
  child: ListView.builder( // or a CustomScrollView, GridView, PageView
    itemCount: items.length,
    itemBuilder: (context, i) => FeedSlot(
      index: i,
      child: ValueListenableBuilder<FeedItemState>(
        valueListenable: feed.stateOf(i),
        builder: (context, state, _) => MyCell(playing: state.playing),
      ),
    ),
  ),
);
```

Pass `FeedPolicy.pager()` and a `PlayerPool` for one playing page with
warm neighbours (`state.lease`).

## Features

- Player pool keyed by `MediaKey`; leases share one player, so hand-offs
  keep position and buffer
- One immutable `PlayerState` per player; the playhead is read per frame
- `PlayerBudget` of playing and prepared engines, coldest released first
- `PlayerView` with a stand-in until the first frame
- `NativePlayerBackend` (`native.dart`): Media3 ExoPlayer on Android,
  AVPlayer on iOS and macOS, each into its own texture, reading bytes
  through `http_bytes_cache`'s native reader; HDR tone-mapped to SDR
- `PlayerDevice`: the hardware probe and the prepared-player gate
  (`PlayerDevice.budget`); a codec whose decoder failed is skipped next time
- Picture in picture (`PlayerPool.startPictureInPicture`) and background
  audio
- One sound owner app-wide: a new audible player pauses the previous;
  calls, other apps and headphones go through the backend's `AudioFocus`
- `FakePlayerBackend` and the `PlayerEngine`, `AudioFocus` and
  `PictureInPicture` contracts in `testing.dart`
- `FeedPolicy`: the 25 feed knobs with reference defaults per mode;
  `FeedListPlanner` decides what a list plays, shows in view and preloads
- `FeedPager`: the pager mode; the page shown plays with sound, neighbours
  keep prepared players inside the budget, a swipe takes one over
- `FeedSignals`: network, power and heat from the host's own listenables
- `FeedController` + `FeedSlot`: the feed inside any scrollable (lists,
  grids, slivers, pagers, nested lists); each item's decision is a
  `ValueListenable<FeedItemState>`

## Docs

- [Spec](../../docs/spec.md)
- [Package topology (ADR 0001)](../../docs/adr/0001-package-topology.md)
- [ADR 0004](../../docs/adr/0004-player.md)
