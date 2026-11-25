import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/mpx_player.dart';

const _mib = 1024 * 1024;

FeedItem _item(int index, {int? bytes, bool local = false}) =>
    FeedItem(MediaKey.remote('clip-$index'), byteSize: bytes, local: local);

void main() {
  const policy = FeedPolicy.list();

  FeedListPlan plan(
    Map<int, double> visible, {
    FeedPolicy with_ = policy,
    FeedConditions conditions = const FeedConditions(),
    int itemCount = 20,
    FeedScrollDirection direction = FeedScrollDirection.forward,
    bool fast = false,
    Map<int, double> centres = const {},
    FeedItem? Function(int)? item,
  }) => FeedListPlanner(with_, conditions: conditions).plan(
    FeedListViewport(
      itemCount: itemCount,
      visible: visible,
      centreDistances: centres,
      direction: direction,
      fastScroll: fast,
    ),
    item ?? _item,
  );

  group('1 mode', () {
    test('list mode by the list constructor', () {
      expect(policy.mode, FeedMode.list);
      expect(const FeedPolicy.pager().mode, FeedMode.pager);
    });
  });

  group('2 active item', () {
    test('every visible clip plays; the most visible one is in view', () {
      final result = plan({3: 0.3, 4: 1, 5: 0.6});

      expect(result.playing, unorderedEquals([3, 4, 5]));
      expect(result.inView, 4);
    });

    test('nothing is in view below the threshold of one half', () {
      expect(plan({3: 0.4, 4: 0.45}).inView, isNull);
    });

    test('a tie goes to the item nearer the centre', () {
      final result = plan({3: 1, 4: 1}, centres: {3: 120, 4: 10});

      expect(result.inView, 4);
    });

    test('nearest centre first when the rule says so', () {
      const centred = FeedPolicy.list(
        activeItem: FeedActiveItemRule(tieBreak: FeedTieBreak.nearestCentre),
      );
      final result = plan(
        {3: 1, 4: 0.6},
        with_: centred,
        centres: {3: 200, 4: 5},
      );

      expect(result.inView, 4);
    });

    test('the advance floor of a quarter reaches the clip profile', () {
      expect(policy.activeItem.advanceFloor, 0.25);
      expect(policy.clipProfile().advanceFloor, 0.25);
      expect(policy.clipProfile().animate, isTrue);
    });
  });

  group('unknown items', () {
    test('an index without facts neither plays nor preloads', () {
      final result = plan({
        3: 1,
        4: 0.6,
      }, item: (i) => i == 4 || i > 5 ? null : _item(i));

      expect(result.autoplay.keys, [3]);
      expect(result.inView, 3);
      expect(result.preloads.keys, [5]);
    });
  });

  group('the in-view pick', () {
    test('picks the most visible above the threshold, then the nearer', () {
      const rule = FeedActiveItemRule();

      expect(rule.pick({1: 0.4, 2: 0.45}), isNull);
      expect(rule.pick({1: 0.6, 2: 0.9}), 2);
      expect(rule.pick({1: 1, 2: 1}, centreDistances: {1: 50, 2: 10}), 2);
      expect(rule.pick({1: 1, 2: 1}), 1);
    });
  });

  group('3 autoplay gate and 4 size limits', () {
    const metered = FeedConditions(network: FeedNetwork.metered);

    test('a file within the limit plays in full', () {
      expect(
        plan(
          {0: 1},
          conditions: metered,
          item: (i) => _item(i, bytes: _mib),
        ).autoplay[0],
        FeedAutoplay.full,
      );
    });

    test('limits are 15 MiB unmetered, 10 MiB metered, 500 KiB roaming', () {
      const limits = FeedSizeLimits();
      expect(limits.limitOn(FeedNetwork.unmetered), 15 * _mib);
      expect(limits.limitOn(FeedNetwork.metered), 10 * _mib);
      expect(limits.limitOn(FeedNetwork.roaming), 500 * 1024);
      expect(limits.limitOn(FeedNetwork.none), 0);
    });

    test('a file over the limit gets a prefix when the limit allows one', () {
      final autoplay = plan(
        {0: 1},
        conditions: metered,
        item: (i) => _item(i, bytes: 12 * _mib),
      ).autoplay[0];

      expect(autoplay, FeedAutoplay.prefixOnly);
    });

    test('over a small limit nothing plays', () {
      final autoplay = plan(
        {0: 1},
        conditions: const FeedConditions(network: FeedNetwork.roaming),
        item: (i) => _item(i, bytes: _mib),
      ).autoplay[0];

      expect(autoplay, FeedAutoplay.none);
    });

    test('no network stops autoplay; local files play', () {
      for (final conditions in const [
        FeedConditions(network: FeedNetwork.none),
      ]) {
        expect(
          plan({0: 1}, conditions: conditions).autoplay[0],
          FeedAutoplay.none,
        );
        expect(
          plan(
            {0: 1},
            conditions: conditions,
            item: (i) => _item(i, local: true),
          ).autoplay[0],
          FeedAutoplay.full,
        );
      }
    });

    test('a host gate replaces the standard one', () {
      final never = FeedPolicy.list(
        autoplayGate: (item, conditions, policy) => FeedAutoplay.none,
      );

      expect(plan({0: 1}, with_: never).playing, isEmpty);
    });
  });

  group('5 muted autoplay', () {
    test('list clips play muted, pager items with sound', () {
      expect(policy.mutedAutoplay, isTrue);
      expect(const FeedPolicy.pager().mutedAutoplay, isFalse);
    });
  });

  group('10 window and 11 staging', () {
    test('three items ahead in the scroll direction get their first frame', () {
      final result = plan({4: 1, 5: 0.5});

      expect(result.preloads, {
        6: AssetPreloadStage.firstFrame,
        7: AssetPreloadStage.firstFrame,
        8: AssetPreloadStage.firstFrame,
      });
    });

    test('scrolling back preloads below the first visible item', () {
      final result = plan({
        4: 1,
        5: 0.5,
      }, direction: FeedScrollDirection.backward);

      expect(result.preloads.keys, unorderedEquals([3, 2, 1]));
      expect(result.distances, {3: 1, 2: 2, 1: 3});
    });

    test('the window stops at the ends of the list', () {
      expect(plan({18: 1}).preloads.keys, [19]);
      expect(
        plan({1: 1}, direction: FeedScrollDirection.backward).preloads.keys,
        [0],
      );
    });

    test('no visible item, no preload', () {
      expect(plan({}).preloads, isEmpty);
    });

    test('a wider window and the pager staging by distance', () {
      const wide = FeedPolicy.list(
        preloadWindow: FeedPreloadWindow(ahead: 2, behind: 1),
        preloadStaging: FeedPolicy.pagerStaging,
      );
      final result = plan({5: 1}, with_: wide);

      expect(result.preloads, {
        6: const AssetPreloadStage.seconds(Duration(seconds: 5)),
        7: AssetPreloadStage.metadata,
        4: const AssetPreloadStage.seconds(Duration(seconds: 3)),
      });
    });

    test('pager staging: +1 5 s, -1 3 s, up to four metadata, then none', () {
      expect(
        FeedPolicy.pagerStaging(1),
        const AssetPreloadStage.seconds(Duration(seconds: 5)),
      );
      expect(
        FeedPolicy.pagerStaging(-1),
        const AssetPreloadStage.seconds(Duration(seconds: 3)),
      );
      expect(FeedPolicy.pagerStaging(4), AssetPreloadStage.metadata);
      expect(FeedPolicy.pagerStaging(-4), AssetPreloadStage.metadata);
      expect(FeedPolicy.pagerStaging(5), isNull);
    });

    test('a fast scroll starts nothing heavier than a first frame', () {
      const wide = FeedPolicy.list(preloadStaging: FeedPolicy.pagerStaging);
      final result = plan({5: 1}, with_: wide, fast: true);

      expect(result.preloads[6], AssetPreloadStage.metadata);
    });

    test('an item that will not autoplay preloads its metadata only', () {
      final result = plan({
        5: 1,
      }, conditions: const FeedConditions(batteryLevel: 5));

      expect(result.preloads.values.toSet(), {AssetPreloadStage.metadata});
    });
  });

  group('12 oversize prefix', () {
    test('a prefix-only item preloads at most the prefix', () {
      const wide = FeedPolicy.list(
        preloadStaging: _tenSeconds,
        oversizePrefix: FeedOversizePrefix(duration: Duration(seconds: 2)),
      );
      final result = plan(
        {5: 1},
        with_: wide,
        conditions: const FeedConditions(network: FeedNetwork.metered),
        item: (i) => _item(i, bytes: 20 * _mib),
      );

      expect(
        result.preloads[6],
        const AssetPreloadStage.seconds(Duration(seconds: 2)),
      );
    });

    test('defaults to 4 s capped at 2 MiB', () {
      expect(policy.oversizePrefix!.duration, const Duration(seconds: 4));
      expect(policy.oversizePrefix!.maxBytes, 2 * _mib);
    });

    test('without a prefix an oversize file does not autoplay', () {
      const noPrefix = FeedPolicy.list(oversizePrefix: null);
      final autoplay = plan(
        {0: 1},
        with_: noPrefix,
        item: (i) => _item(i, bytes: 20 * _mib),
      ).autoplay[0];

      expect(autoplay, FeedAutoplay.none);
    });
  });

  group('13, 14, 20, 21, 23', () {
    test('list defaults', () {
      expect(policy.cancelOnLeave, isTrue);
      expect(policy.playerBudget, const PlayerBudget(prepared: 0));
      expect(
        policy.preloadBackOffLayers,
        AssetCacheScope.standardPreloadPausingLayers,
      );
      expect(policy.pausingLayers, FeedPolicy.standardPausingLayers);
      expect(
        policy.pausingLayers,
        PlaybackPolicy.standardPausingLayers.difference({
          PlaybackPauseLayer.lowPower,
        }),
      );
      expect(policy.loop, isTrue);
      expect(policy.clipProfile().loop, isTrue);
      expect(const FeedPolicy.list(loop: false).clipProfile().loop, isFalse);
    });

    test('the pager keeps two players prepared', () {
      expect(
        const FeedPolicy.pager().playerBudget,
        const PlayerBudget(prepared: 2),
      );
    });
  });
}

AssetPreloadStage? _tenSeconds(int distance) =>
    const AssetPreloadStage.seconds(Duration(seconds: 10));
