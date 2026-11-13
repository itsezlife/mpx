import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_player/testing.dart';

MediaKey keyOf(int index) => MediaKey.remote('reel-$index');

FeedItem itemOf(int index) => FeedItem(keyOf(index));

void main() {
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('FeedPagerPlanner', () {
    const planner = FeedPagerPlanner(FeedPolicy.pager());

    test('one active item, the neighbours warm, nearest ahead first', () {
      final plan = planner.plan(index: 3, itemCount: 10, item: itemOf);

      expect(plan.active, 3);
      expect(plan.autoplay, FeedAutoplay.full);
      expect(plan.warm, [4, 2]);
    });

    test('the prepared count is capped by the budget', () {
      final plan = planner.plan(
        index: 3,
        itemCount: 10,
        item: itemOf,
        preparedCap: 1,
      );
      expect(plan.warm, [4]);
    });

    test('the window ends at the edges', () {
      expect(planner.plan(index: 0, itemCount: 3, item: itemOf).warm, [1]);
      expect(planner.plan(index: 2, itemCount: 3, item: itemOf).warm, [1]);
    });

    test('preloads are staged: next 5 s, previous 3 s', () {
      final plan = planner.plan(index: 3, itemCount: 10, item: itemOf);
      expect(plan.preloads, {
        4: const AssetPreloadStage.seconds(Duration(seconds: 5)),
        2: const AssetPreloadStage.seconds(Duration(seconds: 3)),
      });
      expect(plan.distances, {4: 1, 2: 1});
    });

    test('neighbours without facts are neither warmed nor preloaded', () {
      final plan = planner.plan(
        index: 3,
        itemCount: 10,
        item: (i) => i == 4 ? null : itemOf(i),
      );

      expect(plan.warm, [2]);
      expect(plan.preloads.keys, [2]);
    });

    test('items the gate holds back are neither played nor warmed', () {
      const saving = FeedPagerPlanner(
        FeedPolicy.pager(),
        conditions: FeedConditions(powerSaving: true),
      );
      final plan = saving.plan(index: 3, itemCount: 10, item: itemOf);

      expect(plan.autoplay, FeedAutoplay.none);
      expect(plan.warm, isEmpty);
      expect(plan.preloads.values, everyElement(AssetPreloadStage.metadata));
    });
  });

  group('FeedPager', () {
    late FakePlayerBackend backend;
    late PlayerPool pool;

    setUp(() {
      backend = FakePlayerBackend();
      pool = PlayerPool(backend: backend);
    });
    tearDown(() => pool.dispose());

    FeedPager makePager({
      int index = 0,
      FeedPolicy policy = const FeedPolicy.pager(),
      ValueListenable<FeedConditions>? conditions,
      ValueChanged<int>? onAdvance,
      bool? muted = false,
    }) {
      final pager = FeedPager(
        pool: pool,
        itemCount: 10,
        itemOf: itemOf,
        policy: policy,
        conditions: conditions,
        initialIndex: index,
        muted: muted,
        onAdvance: onAdvance,
      );
      addTearDown(pager.dispose);
      return pager;
    }

    test('plays the active item with sound and prepares two', () async {
      final pager = makePager(index: 3);
      await settle();

      expect(pager.leaseOf(3)!.state.value.playing, isTrue);
      expect(pool.soundOwner, keyOf(3));
      for (final warm in [2, 4]) {
        final state = pager.leaseOf(warm)!.state.value;
        expect(state.phase, PlayerPhase.ready);
        expect(state.playing, isFalse);
      }
      expect(backend.live, hasLength(3));
    });

    test('a swipe takes over the prepared player', () async {
      final pager = makePager(index: 3);
      await settle();
      final prepared = backend.latestFor(keyOf(4))!;

      pager.show(4);
      await settle();

      // The engine prepared for 4 plays now; none was created for it.
      expect(backend.latestFor(keyOf(4)), same(prepared));
      expect(prepared.state.value.playing, isTrue);
      expect(pool.soundOwner, keyOf(4));
      expect(pager.leaseOf(3)!.state.value.playing, isFalse);
      expect(pager.leaseOf(5)!.state.value.phase, PlayerPhase.ready);
      expect(pager.leaseOf(2), isNull);
    });

    test('never holds more than the budget', () async {
      final pager = makePager(index: 3);
      await settle();
      for (final index in [4, 5, 6, 7]) {
        pager.show(index);
        await settle();
        expect(backend.live.length, lessThanOrEqualTo(3));
        final holding = backend.live
            .where((engine) => !engine.state.value.playing)
            .length;
        expect(holding, lessThanOrEqualTo(2));
      }
    });

    test('a smaller prepared budget warms only the next item', () async {
      pool.budget = const PlayerBudget(prepared: 1);
      final pager = makePager(index: 3);
      await settle();

      expect(pager.leaseOf(4), isNotNull);
      expect(pager.leaseOf(2), isNull);
      expect(backend.live, hasLength(2));
    });

    test('the pager restarts an item it comes back to', () async {
      final pager = makePager(index: 3);
      await settle();
      backend.latestFor(keyOf(3))!.advance(const Duration(seconds: 8));

      pager.show(4);
      await settle();
      pager.show(3);
      await settle();

      expect(pager.leaseOf(3)!.position, Duration.zero);
    });

    test('mute is session-wide: the active and the prepared ones', () async {
      final pager = makePager(index: 3, muted: true);
      await settle();

      expect(pool.soundOwner, isNull);
      expect(pager.leaseOf(4)!.state.value.volume, 0);

      pager.muted = false;
      expect(pool.soundOwner, keyOf(3));
      expect(pager.leaseOf(4)!.state.value.volume, 1);
    });

    test(
      'without a mute given, the initial mute of the policy decides',
      () async {
        final muted = makePager(
          muted: null,
          policy: const FeedPolicy.pager(initialMute: FeedInitialMute.muted),
        );
        expect(muted.muted, isTrue);

        final unmuted = makePager(
          muted: null,
          policy: const FeedPolicy.pager(initialMute: FeedInitialMute.unmuted),
        );
        expect(unmuted.muted, isFalse);
      },
    );

    test('following the ringer mutes with it until the user toggles', () {
      final silenced = ValueNotifier(true);
      addTearDown(silenced.dispose);
      final signals = FeedSignals(silenced: silenced);
      addTearDown(signals.dispose);
      final pager = makePager(muted: null, conditions: signals);
      expect(pager.muted, isTrue);

      silenced.value = false;
      expect(pager.muted, isFalse);

      pager.muted = true;
      silenced.value = true;
      silenced.value = false;
      expect(pager.muted, isTrue);
    });

    test('an item that ends asks for the next one', () async {
      final advanced = <int>[];
      makePager(index: 3, onAdvance: advanced.add);
      await settle();

      backend.latestFor(keyOf(3))!.advance(const Duration(minutes: 2));
      await settle();

      expect(advanced, [4]);
    });

    test('new conditions re-plan: power saving stops autoplay', () async {
      final conditions = ValueNotifier(const FeedConditions());
      addTearDown(conditions.dispose);
      final pager = makePager(index: 3, conditions: conditions);
      await settle();

      conditions.value = const FeedConditions(powerSaving: true);
      await settle();

      expect(pager.leaseOf(3)!.state.value.playing, isFalse);
      expect(pager.leaseOf(4), isNull);
    });

    test('dispose releases every lease', () async {
      final pager = makePager(index: 3);
      await settle();
      pager.dispose();

      expect(pool.soundOwner, isNull);
      expect(pager.leaseOf(3), isNull);
    });
  });
}
