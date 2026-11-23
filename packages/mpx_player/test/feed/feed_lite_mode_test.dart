import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/mpx_player.dart';

FeedItem _video({bool local = false}) =>
    FeedItem(const MediaKey.remote('video'), byteSize: 1024, local: local);

FeedItem _gif({bool local = false}) => FeedItem(
  const MediaKey.remote('gif'),
  byteSize: 1024,
  local: local,
  descriptor: const MediaDescriptor(
    key: MediaKey.remote('gif'),
    kind: MediaKind.video,
    animated: true,
    silentLoop: true,
  ),
);

/// The reference clients' lite mode: what autoplays is the reader's choice
/// per kind, and the power saver is a battery level, not the system's mode.
void main() {
  group('the power saver', () {
    test('is the battery at or under the level, 10 % by default', () {
      const policy = FeedPolicy.list();

      expect(
        policy.autoplayOf(_video(), const FeedConditions(batteryLevel: 11)),
        FeedAutoplay.full,
      );
      expect(
        policy.autoplayOf(_video(), const FeedConditions(batteryLevel: 10)),
        FeedAutoplay.none,
      );
    });

    test('stops what is on the device too: autoplay is the reader\'s '
        'setting first', () {
      const policy = FeedPolicy.list();

      expect(
        policy.autoplayOf(
          _video(local: true),
          const FeedConditions(batteryLevel: 5),
        ),
        FeedAutoplay.none,
      );
    });

    test('does not stop a device whose battery is unknown', () {
      expect(
        const FeedPolicy.list().autoplayOf(_video(), const FeedConditions()),
        FeedAutoplay.full,
      );
    });

    test('is never applied at level 0, and always at level 100', () {
      const never = FeedPolicy.list(lite: FeedLiteMode(powerSaverLevel: 0));
      const always = FeedPolicy.list(lite: FeedLiteMode(powerSaverLevel: 100));
      const low = FeedConditions(batteryLevel: 1);

      expect(never.autoplayOf(_video(), low), FeedAutoplay.full);
      expect(
        always.autoplayOf(_video(), const FeedConditions()),
        FeedAutoplay.none,
      );
    });

    test('is not the system\'s battery saver, unless the host says so', () {
      const saving = FeedConditions(powerSaving: true);

      expect(
        const FeedPolicy.list().autoplayOf(_video(), saving),
        FeedAutoplay.full,
      );
      expect(
        const FeedPolicy.list(
          lite: FeedLiteMode(osPowerSaverCounts: true),
        ).autoplayOf(_video(), saving),
        FeedAutoplay.none,
      );
    });

    test('is not a layer that pauses the clock: the reader can still play '
        'what they asked for', () {
      expect(
        const FeedPolicy.list().pausingLayers,
        isNot(contains(PlaybackPauseLayer.lowPower)),
      );
      expect(
        const FeedPolicy.pager().pausingLayers,
        isNot(contains(PlaybackPauseLayer.lowPower)),
      );
    });
  });

  group('the autoplay settings', () {
    test('are per kind: videos and GIFs apart', () {
      const noVideos = FeedPolicy.list(
        lite: FeedLiteMode(autoplayVideos: false),
      );
      const noGifs = FeedPolicy.list(lite: FeedLiteMode(autoplayGifs: false));
      const conditions = FeedConditions();

      expect(noVideos.autoplayOf(_video(), conditions), FeedAutoplay.none);
      expect(noVideos.autoplayOf(_gif(), conditions), FeedAutoplay.full);
      expect(noGifs.autoplayOf(_video(), conditions), FeedAutoplay.full);
      expect(noGifs.autoplayOf(_gif(), conditions), FeedAutoplay.none);
    });

    test('both are on by default', () {
      const lite = FeedLiteMode();

      expect(lite.autoplayVideos, isTrue);
      expect(lite.autoplayGifs, isTrue);
      expect(lite.powerSaverLevel, 10);
      expect(lite.osPowerSaverCounts, isFalse);
    });
  });

  test('a device with no network still plays what it has', () {
    const none = FeedConditions(network: FeedNetwork.none);

    expect(
      const FeedPolicy.list().autoplayOf(_video(local: true), none),
      FeedAutoplay.full,
    );
    expect(
      const FeedPolicy.list().autoplayOf(_video(), none),
      FeedAutoplay.none,
    );
  });
}
