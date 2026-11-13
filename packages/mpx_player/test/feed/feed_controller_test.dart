import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_player/testing.dart';

MediaKey _key(int index) => MediaKey.remote('clip-$index');

FeedItem _item(int index) => FeedItem(_key(index));

AssetPreset _preset(int index, AssetProfile profile) => AssetPreset(
  size: const Size(100, 100),
  spec: const AssetSpec(pixelWidth: 100, pixelHeight: 100),
  profile: profile,
);

void main() {
  late FakeAssetProducer producer;
  late PlaybackClock clock;
  late AssetCacheScope scope;

  setUp(() {
    producer = FakeAssetProducer();
    clock = PlaybackClock(ticks: ManualPlaybackTickSource());
    scope = AssetCacheScope(producer: producer, clock: clock);
  });
  tearDown(() {
    scope.dispose();
    clock.dispose();
  });

  List<FakeAssetAttempt> attemptsFor(int index) => [
    for (final attempt in producer.attempts)
      if (attempt.request.key == _key(index)) attempt,
  ];

  /// Registers [fractions] (index to visible fraction) as slots whose
  /// measure reads the map live.
  Map<int, FeedSlotRegistration> slots(
    FeedController controller,
    Map<int, double> fractions,
  ) => {
    for (final index in fractions.keys.toList())
      index: controller.register(
        index,
        item: _item(index),
        measure: () => FeedVisibility(fraction: fractions[index] ?? 0),
      ),
  };

  group('list mode', () {
    test('the measured fractions decide what plays and what is in view', () {
      final controller = FeedController();
      addTearDown(controller.dispose);
      slots(controller, {0: 0.3, 1: 1, 2: 0.6, 3: 0});

      controller.measure();

      expect(controller.inView.value, 1);
      final states = [for (var i = 0; i < 4; i++) controller.stateOf(i).value];
      expect(states.map((s) => s.playing), [true, true, true, false]);
      expect(states.map((s) => s.inView), [false, true, false, false]);
      expect(states.map((s) => s.fraction), [0.3, 1, 0.6, 0]);
      expect(states.every((s) => s.muted), isTrue);
    });

    test('items ahead preload through the scope; dispose cancels them', () {
      final controller = FeedController(
        itemCount: 20,
        itemOf: _item,
        presetOf: _preset,
        scope: scope,
      );
      slots(controller, {0: 1, 1: 0.5});

      controller.measure();

      expect(controller.stateOf(3).value.preload, AssetPreloadStage.firstFrame);
      final ahead = [2, 3, 4].map((i) => attemptsFor(i).single).toList();
      expect(ahead.map((a) => a.demand.distance), [1, 2, 3]);
      expect(attemptsFor(5), isEmpty);

      controller.dispose();
      expect(ahead.every((attempt) => attempt.isCancelled), isTrue);
    });

    test('without facts ahead only the registered items count', () {
      final controller = FeedController(presetOf: _preset, scope: scope);
      addTearDown(controller.dispose);
      slots(controller, {0: 1, 1: 0.5, 2: 0});

      controller.measure();

      expect(attemptsFor(2).single.demand.preloadStage, isNotNull);
      expect(attemptsFor(3), isEmpty);
    });

    test('a slot that moves to another index takes its state along', () {
      final controller = FeedController();
      addTearDown(controller.dispose);
      final registered = slots(controller, {0: 1});
      controller.measure();

      registered[0]!.update(index: 7, item: _item(7));
      controller.measure();

      expect(controller.stateOf(0).value.visible, isFalse);
      expect(controller.stateOf(7).value.playing, isTrue);
    });

    test('an unregistered slot stops counting', () {
      final controller = FeedController();
      addTearDown(controller.dispose);
      final registered = slots(controller, {0: 1, 1: 1});
      controller.measure();

      registered[0]!.unregister();
      controller.measure();

      expect(controller.stateOf(0).value.playing, isFalse);
      expect(controller.inView.value, 1);
    });

    test('the conditions plan again', () {
      final saving = ValueNotifier(false);
      addTearDown(saving.dispose);
      final signals = FeedSignals(powerSaving: saving);
      addTearDown(signals.dispose);
      final controller = FeedController(conditions: signals);
      addTearDown(controller.dispose);
      slots(controller, {0: 1});
      controller.measure();
      expect(controller.stateOf(0).value.playing, isTrue);

      saving.value = true;

      expect(controller.stateOf(0).value.autoplay, FeedAutoplay.none);
      expect(controller.stateOf(0).value.playing, isFalse);
    });

    testWidgets('a slot asking to be measured is measured after the frame', (
      tester,
    ) async {
      final controller = FeedController();
      addTearDown(controller.dispose);
      final fractions = {0: 0.0};
      final registered = slots(controller, fractions);
      await tester.pump();
      expect(controller.stateOf(0).value.visible, isFalse);

      fractions[0] = 0.8;
      registered[0]!.markNeedsMeasure();
      expect(controller.stateOf(0).value.visible, isFalse);
      await tester.pump();

      expect(controller.stateOf(0).value.fraction, 0.8);
    });
  });

  group('policy knobs', () {
    test('a pausing layer of the policy stops what plays', () {
      final controller = FeedController(
        policy: const FeedPolicy.list(
          pausingLayers: {PlaybackPauseLayer.lowPower},
        ),
        scope: scope,
      );
      addTearDown(controller.dispose);
      slots(controller, {0: 1});
      controller.measure();
      expect(controller.stateOf(0).value.playing, isTrue);

      clock.setPaused(PlaybackPauseLayer.lowPower, paused: true);
      expect(controller.stateOf(0).value.playing, isFalse);

      clock.setPaused(PlaybackPauseLayer.lowPower, paused: false);
      expect(controller.stateOf(0).value.playing, isTrue);
    });

    test('a back-off layer of the policy starts no preloads', () {
      final controller = FeedController(
        policy: const FeedPolicy.list(
          preloadBackOffLayers: {PlaybackPauseLayer.meteredNetwork},
        ),
        itemCount: 20,
        itemOf: _item,
        presetOf: _preset,
        scope: scope,
      );
      addTearDown(controller.dispose);
      clock.setPaused(PlaybackPauseLayer.meteredNetwork, paused: true);
      slots(controller, {0: 1});
      controller.measure();
      expect(attemptsFor(1), isEmpty);

      clock.setPaused(PlaybackPauseLayer.meteredNetwork, paused: false);
      expect(attemptsFor(1).single.demand.preloadStage, isNotNull);
    });

    test('an item further than the unload distance is released', () {
      final controller = FeedController(
        policy: const FeedPolicy.list(heavyUnloadViewports: 2),
      );
      addTearDown(controller.dispose);
      for (final (index, away) in [(0, 0.0), (1, 1.5), (2, 3.0)]) {
        controller.register(
          index,
          item: _item(index),
          measure: () =>
              FeedVisibility(fraction: away == 0 ? 1 : 0, viewportsAway: away),
        );
      }
      controller.measure();

      expect(
        [for (var i = 0; i < 3; i++) controller.stateOf(i).value.released],
        [false, false, true],
      );
    });

    test('a decision nobody listens to or registers is dropped and freed', () {
      final controller = FeedController();
      addTearDown(controller.dispose);
      final unheard = controller.stateOf(9) as ChangeNotifier;

      controller.measure();

      expect(
        () => ChangeNotifier.debugAssertNotDisposed(unheard),
        throwsFlutterError,
      );
    });
  });

  group('pager mode', () {
    late FakePlayerBackend backend;
    late PlayerPool pool;

    setUp(() {
      backend = FakePlayerBackend();
      pool = PlayerPool(backend: backend);
    });
    tearDown(() => pool.dispose());

    test('the most visible page plays; its neighbour is leased warm', () {
      final controller = FeedController(
        policy: const FeedPolicy.pager(),
        pool: pool,
        itemCount: 10,
        itemOf: _item,
      );
      addTearDown(controller.dispose);
      final fractions = {0: 1.0, 1: 0.0};
      slots(controller, fractions);
      controller.measure();

      expect(controller.inView.value, 0);
      expect(pool.soundOwner, _key(0));
      expect(controller.stateOf(0).value.lease, isNotNull);
      expect(controller.stateOf(0).value.playing, isTrue);
      expect(controller.stateOf(0).value.muted, isFalse);
      expect(controller.stateOf(1).value.lease, isNotNull);
      expect(controller.stateOf(1).value.playing, isFalse);

      fractions
        ..[0] = 0.3
        ..[1] = 0.7;
      controller.measure();

      expect(controller.inView.value, 1);
      expect(controller.pager!.index, 1);
      expect(pool.soundOwner, _key(1));
    });

    test('no page above the threshold keeps the one playing', () {
      final controller = FeedController(
        policy: const FeedPolicy.pager(),
        pool: pool,
        itemOf: _item,
        itemCount: 10,
        initialIndex: 2,
      );
      addTearDown(controller.dispose);
      slots(controller, {2: 0.4, 3: 0.4});
      controller.measure();

      expect(controller.inView.value, 2);
    });

    test('mute reaches every lease; dispose releases them', () {
      final controller = FeedController(
        policy: const FeedPolicy.pager(),
        pool: pool,
        itemCount: 10,
        itemOf: _item,
      );
      slots(controller, {0: 1});
      controller.measure();

      controller.pager!.muted = true;

      expect(controller.stateOf(0).value.muted, isTrue);
      expect(pool.soundOwner, isNull);

      final lease = controller.stateOf(0).value.lease!;
      controller.dispose();
      expect(lease.isReleased, isTrue);
    });
  });
}
