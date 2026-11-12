import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_player/testing.dart';
import 'package:mpx_ui/mpx_ui.dart';

const _viewport = Size(400, 800);

MediaKey _key(int index) => MediaKey.remote('reel-$index');

void main() {
  late FakePlayerBackend backend;
  late PlayerPool pool;
  late FakeAssetProducer producer;
  late PlaybackClock clock;
  late AssetCacheScope scope;

  setUp(() {
    backend = FakePlayerBackend();
    pool = PlayerPool(backend: backend);
    producer = FakeAssetProducer();
    clock = PlaybackClock(ticks: ManualPlaybackTickSource());
    scope = AssetCacheScope(producer: producer, clock: clock);
  });
  tearDown(() {
    pool.dispose();
    scope.dispose();
    clock.dispose();
  });

  AssetPreset preset(int index, AssetProfile profile) => AssetPreset(
    size: _viewport,
    spec: const AssetSpec(pixelWidth: 400, pixelHeight: 800),
    profile: profile,
  );

  Future<void> pumpPager(WidgetTester tester, {bool muted = false}) async {
    tester.view.physicalSize = _viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: FeedPagerView(
          pool: pool,
          itemCount: 10,
          itemOf: (index) => FeedItem(_key(index)),
          presetOf: preset,
          scope: scope,
          muted: muted,
          posterBuilder: (context, index) => Text('poster $index'),
        ),
      ),
    );
    await tester.pump();
  }

  FeedPager pagerOf(WidgetTester tester) =>
      tester.state<FeedPagerViewState>(find.byType(FeedPagerView)).pager;

  testWidgets('the first page plays with sound and the next is prepared', (
    tester,
  ) async {
    await pumpPager(tester);

    expect(pool.soundOwner, _key(0));
    expect(backend.latestFor(_key(1))!.state.value.phase, PlayerPhase.ready);
    expect(find.byType(Texture), findsOneWidget);
    expect(find.text('poster 0'), findsNothing);
  });

  testWidgets('a swipe takes over the prepared player', (tester) async {
    await pumpPager(tester);
    final prepared = backend.latestFor(_key(1))!;

    await tester.drag(find.byType(PageView), const Offset(0, -500));
    await tester.pumpAndSettle();

    expect(pagerOf(tester).index, 1);
    expect(backend.latestFor(_key(1)), same(prepared));
    expect(pool.soundOwner, _key(1));
    expect(backend.latestFor(_key(2))!.state.value.phase, PlayerPhase.ready);
  });

  testWidgets('neighbours are preloaded to their stage', (tester) async {
    await pumpPager(tester);

    final keys = producer.attempts.map((attempt) => attempt.request.key);
    expect(keys, contains(_key(1)));
  });

  testWidgets('the mute toggle reaches the pager', (tester) async {
    await pumpPager(tester, muted: true);
    expect(pool.soundOwner, isNull);

    await pumpPager(tester);
    expect(pool.soundOwner, _key(0));
  });
}
