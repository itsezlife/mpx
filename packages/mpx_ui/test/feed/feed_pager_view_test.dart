import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_player/testing.dart';
import 'package:mpx_ui/mpx_ui.dart';

const _viewport = Size(400, 800);

MediaKey _key(int index) => MediaKey.remote('reel-$index');

int _index(MediaKey key) => List.generate(10, _key).indexOf(key);

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
    // The player fades in over the poster, which then is not drawn.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
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

  testWidgets('a page whose player buffers shows the spinner only past '
      '500 ms', (tester) async {
    await pumpPager(tester);
    final engine = backend.latestFor(_key(0))!;
    Finder spinner() => find.descendant(
      of: find.byType(ViewerBufferingSpinner),
      matching: find.byType(MediaStatusControl),
    );

    engine.stall();
    await tester.pump(const Duration(milliseconds: 300));
    engine.resume();
    await tester.pump(const Duration(milliseconds: 600));
    expect(spinner(), findsNothing);

    engine.stall();
    await tester.pump(const Duration(milliseconds: 499));
    expect(spinner(), findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    expect(spinner(), findsOneWidget);

    engine.resume();
    await tester.pump();
    expect(spinner(), findsNothing);
  });

  testWidgets('a page that downloads has one centre control: no spinner '
      'beside its status radial', (tester) async {
    tester.view.physicalSize = _viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: FeedPagerView(
          pool: pool,
          itemCount: 3,
          itemOf: (index) => FeedItem(_key(index)),
          presetOf: preset,
          scope: scope,
          status: const MediaStatusMode.control(),
        ),
      ),
    );
    await tester.pump();
    for (final attempt in producer.attempts) {
      if (attempt.request.key == _key(0)) attempt.transfer(1000, 4000);
    }
    backend.latestFor(_key(0))!.stall();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.descendant(
        of: find.byType(ViewerBufferingSpinner),
        matching: find.byType(MediaStatusControl),
      ),
      findsNothing,
    );

    // Once the bytes are no longer shown, a stalled player shows its spinner.
    for (final attempt in producer.attempts) {
      if (attempt.request.key == _key(0)) attempt.advance(AssetStage.full);
    }
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.descendant(
        of: find.byType(ViewerBufferingSpinner),
        matching: find.byType(MediaStatusControl),
      ),
      findsOneWidget,
    );
  });

  testWidgets('tells the cache the descriptors its items carry', (
    tester,
  ) async {
    tester.view.physicalSize = _viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    MediaDescriptor descriptor(int index) =>
        MediaDescriptor(key: _key(index), kind: MediaKind.video);
    final knownAtAttach = <bool>[];
    producer.onProduce = (attempt) => knownAtAttach.add(
      producer.known.contains(descriptor(_index(attempt.request.key))),
    );
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: FeedPagerView(
          pool: pool,
          itemCount: 10,
          itemOf: (index) =>
              FeedItem(_key(index), descriptor: descriptor(index)),
          presetOf: preset,
          scope: scope,
        ),
      ),
    );
    await tester.pump();

    expect(producer.known, containsAll([descriptor(0), descriptor(1)]));
    expect(knownAtAttach, isNotEmpty);
    expect(knownAtAttach, everyElement(isTrue));
  });

  testWidgets('the mute toggle reaches the pager', (tester) async {
    await pumpPager(tester, muted: true);
    expect(pool.soundOwner, isNull);

    await pumpPager(tester);
    expect(pool.soundOwner, _key(0));
  });
}
