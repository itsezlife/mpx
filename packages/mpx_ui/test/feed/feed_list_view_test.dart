import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_ui/mpx_ui.dart';

const _extent = 200.0;
const _viewport = Size(400, 500);

MediaKey _key(int index) => MediaKey.remote('clip-$index');

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

  AssetPreset preset(int index, AssetProfile profile) => AssetPreset(
    size: const Size(_extent, _extent),
    spec: const AssetSpec(pixelWidth: 200, pixelHeight: 200),
    profile: profile,
  );

  Future<ScrollController> pumpList(
    WidgetTester tester, {
    FeedPolicy policy = const FeedPolicy.list(),
    ValueListenable<FeedConditions>? conditions,
    ValueChanged<int?>? onInView,
    double? itemExtent = _extent,
    Widget Function(BuildContext, int, Widget)? cellBuilder,
  }) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    tester.view.physicalSize = _viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: FeedListView(
          itemCount: 30,
          itemExtent: itemExtent,
          cellBuilder: cellBuilder,
          itemOf: (index) => FeedItem(_key(index)),
          presetOf: preset,
          policy: policy,
          conditions: conditions,
          scope: scope,
          controller: controller,
          onInViewChanged: onInView,
        ),
      ),
    );
    await tester.pump();
    return controller;
  }

  List<FakeAssetAttempt> attemptsFor(int index) => [
    for (final attempt in producer.attempts)
      if (attempt.request.key == _key(index)) attempt,
  ];

  testWidgets('visible clips attach; the items ahead preload first frames', (
    tester,
  ) async {
    await pumpList(tester);

    // 500 px shows items 0 and 1 whole and half of 2.
    for (final index in [0, 1, 2]) {
      expect(
        scope.isAttached(_key(index), preset(0, const AssetProfile()).spec),
        isTrue,
      );
    }
    // Item 3 lies in the list's cache extent: its cell is built, hidden, and
    // its binding wants the whole clip.
    expect(attemptsFor(3).single.demand.priority, AssetPriority.preload);
    expect(attemptsFor(3).single.demand.preloadStage, isNull);
    for (final index in [4, 5]) {
      final attempts = attemptsFor(index);
      expect(attempts, hasLength(1), reason: 'item $index preloads');
      expect(attempts.single.demand.preloadStage, AssetPreloadStage.firstFrame);
      expect(attempts.single.demand.distance, index - 2);
    }
    expect(attemptsFor(6), isEmpty);
  });

  group('without a scroll', () {
    late ManualPlaybackTickSource ticks;

    setUp(() {
      scope.dispose();
      clock.dispose();
      ticks = ManualPlaybackTickSource();
      clock = PlaybackClock(ticks: ticks);
      scope = AssetCacheScope(producer: producer, clock: clock);
    });

    // Gives every clip that asked for its media a playing stage.
    Future<void> decodeAll(WidgetTester tester) async {
      for (final attempt in List.of(producer.attempts)) {
        if (attempt.isCancelled || attempt.paintables.isNotEmpty) continue;
        attempt.advance(
          AssetStage.full,
          tier: AssetTier.animated,
          frames: List.filled(4, const Duration(milliseconds: 100)),
        );
      }
      await tester.pump();
    }

    testWidgets('the visible clips play after the first frames', (
      tester,
    ) async {
      await pumpList(tester);
      await decodeAll(tester);

      expect(ticks.isRunning, isTrue, reason: 'nothing plays');
    });

    testWidgets('the visible clips play once their route comes on stage', (
      tester,
    ) async {
      // A route is built off stage for its first frame while heroes are
      // measured: nothing of it is painted then, and nothing lays out again
      // when it comes on stage.
      tester.view.physicalSize = _viewport;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Navigator(
            key: navigator,
            onGenerateRoute: (_) => PageRouteBuilder<void>(
              pageBuilder: (_, _, _) => const SizedBox.expand(),
            ),
          ),
        ),
      );
      final route = PageRouteBuilder<void>(
        transitionDuration: Duration.zero,
        pageBuilder: (_, _, _) => FeedListView(
          itemCount: 30,
          itemExtent: _extent,
          itemOf: (index) => FeedItem(_key(index)),
          presetOf: preset,
          scope: scope,
        ),
      );
      unawaited(navigator.currentState!.push(route));
      route.offstage = true;
      await tester.pump();
      await tester.pump();

      route.offstage = false;
      await tester.pump();
      await tester.pump();
      await decodeAll(tester);
      await tester.pump();

      expect(ticks.isRunning, isTrue, reason: 'nothing plays');
    });

    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      testWidgets('the visible clips play once a ${platform.name} page route '
          'has come in', (tester) async {
        tester.view.physicalSize = _viewport;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final navigator = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            theme: ThemeData(platform: platform),
            home: const SizedBox.expand(),
          ),
        );
        unawaited(
          navigator.currentState!.push(
            MaterialPageRoute<void>(
              builder: (_) => FeedListView(
                itemCount: 30,
                itemExtent: _extent,
                itemOf: (index) => FeedItem(_key(index)),
                presetOf: preset,
                scope: scope,
              ),
            ),
          ),
        );
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        await decodeAll(tester);
        await tester.pump(const Duration(milliseconds: 50));

        for (final index in [0, 1]) {
          expect(
            scope.isAttached(_key(index), preset(0, const AssetProfile()).spec),
            isTrue,
            reason: 'item $index',
          );
        }
        expect(ticks.isRunning, isTrue, reason: 'nothing plays');
      });
    }
  });

  testWidgets('scrolling moves the window and cancels what left it', (
    tester,
  ) async {
    final controller = await pumpList(tester);
    final firstFive = attemptsFor(5).single;

    controller.jumpTo(_extent * 10);
    await tester.pump();

    expect(firstFive.isCancelled, isTrue);
    // Item 13 is in the cache extent; 14 is preloaded.
    expect(
      attemptsFor(14).single.demand.preloadStage,
      AssetPreloadStage.firstFrame,
    );

    controller.jumpTo(_extent * 5);
    await tester.pump();
    // Scrolling back preloads below the first visible item (3 and 4 are in
    // the cache extent).
    expect(
      attemptsFor(2).last.demand.preloadStage,
      AssetPreloadStage.firstFrame,
    );
  });

  testWidgets('the item in view is reported', (tester) async {
    final inView = <int?>[];
    final controller = await pumpList(tester, onInView: inView.add);

    controller.jumpTo(_extent * 3 + 50);
    await tester.pump();

    // Items 0 and 1 show whole; 1 is nearer the centre.
    expect(inView, [1, 4]);
  });

  testWidgets('clips that do not autoplay attach still', (tester) async {
    // The power saver: a battery at or under the level.
    final battery = ValueNotifier<int?>(5);
    addTearDown(battery.dispose);
    final signals = FeedSignals(batteryLevel: battery);
    addTearDown(signals.dispose);
    await pumpList(tester, conditions: signals);

    for (final index in [0, 1, 2]) {
      expect(attemptsFor(index).single.demand.priority, AssetPriority.visible);
    }
    // Preloads of items that will not play ask for their metadata only.
    expect(
      attemptsFor(4).single.demand.preloadStage,
      AssetPreloadStage.metadata,
    );
  });

  testWidgets('leaving the tree cancels every preload', (tester) async {
    await pumpList(tester);
    final preloads = [4, 5].map((i) => attemptsFor(i).single).toList();

    await tester.pumpWidget(const SizedBox());

    expect(preloads.every((attempt) => attempt.isCancelled), isTrue);
  });

  testWidgets('plans again when the signals change', (tester) async {
    final battery = ValueNotifier<int?>(5);
    addTearDown(battery.dispose);
    final signals = FeedSignals(batteryLevel: battery);
    addTearDown(signals.dispose);
    await pumpList(tester, conditions: signals);
    final metadataOnly = attemptsFor(4).single;
    expect(metadataOnly.demand.preloadStage, AssetPreloadStage.metadata);

    battery.value = 80;
    await tester.pump();

    expect(metadataOnly.isCancelled, isTrue);
    expect(
      attemptsFor(4).last.demand.preloadStage,
      AssetPreloadStage.firstFrame,
    );
  });

  testWidgets('items of mixed extents measure themselves', (tester) async {
    final inView = <int?>[];
    final controller = await pumpList(
      tester,
      itemExtent: null,
      onInView: inView.add,
      cellBuilder: (context, index, clip) =>
          SizedBox(height: index.isEven ? 100 : 300, child: clip),
    );

    // Items sit at 0, 100, 400, 500, 800: 300..800 shows a third of 1 and
    // all of 2 and 3.
    controller.jumpTo(300);
    await tester.pump();

    final feed = tester
        .state<FeedListViewState>(find.byType(FeedListView))
        .feed;
    expect(feed.stateOf(1).value.fraction, closeTo(1 / 3, 1e-9));
    expect(feed.stateOf(2).value.fraction, 1);
    expect(feed.stateOf(3).value.fraction, 1);
    expect(feed.stateOf(4).value.visible, isFalse);
    expect(inView.last, 2);
  });
}
