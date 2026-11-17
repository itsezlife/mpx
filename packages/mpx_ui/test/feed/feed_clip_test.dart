import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_player/testing.dart';
import 'package:mpx_ui/mpx_ui.dart';

MediaKey _key(int index) => MediaKey.remote('clip-$index');

FeedItem _item(int index) => FeedItem(_key(index));

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
    size: const Size(200, 200),
    spec: const AssetSpec(pixelWidth: 200, pixelHeight: 200),
    profile: profile,
  );

  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(400, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: AssetCacheProvider(scope: scope, child: child),
      ),
    );
    await tester.pump();
  }

  testWidgets('a clip whose media has no stage yet paints nothing', (
    tester,
  ) async {
    final feed = FeedController(presetOf: preset);
    addTearDown(feed.dispose);
    await pump(
      tester,
      FeedScope(
        controller: feed,
        child: ListView(
          children: [
            SizedBox(
              height: 200,
              child: FeedSlot(
                index: 0,
                item: _item(0),
                child: const FeedClip(),
              ),
            ),
          ],
        ),
      ),
    );

    final clip = find.byType(ContentView);
    expect(clip, findsOneWidget);
    expect(tester.renderObject(clip), paintsNothing);
  });

  testWidgets('clips in a host grid attach with the plan of the slots', (
    tester,
  ) async {
    final feed = FeedController(presetOf: preset);
    addTearDown(feed.dispose);
    await pump(
      tester,
      FeedScope(
        controller: feed,
        child: CustomScrollView(
          slivers: [
            const SliverToBoxAdapter(child: SizedBox(height: 400)),
            SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
              ),
              itemCount: 10,
              itemBuilder: (context, index) => FeedSlot(
                index: index,
                item: _item(index),
                child: const FeedClip(),
              ),
            ),
          ],
        ),
      ),
    );

    // The first row shows half: both clips play; the rest wait hidden.
    final views = tester
        .widgetList<ContentView>(find.byType(ContentView))
        .toList();
    expect(views.first.visibleFraction, 0.5);
    expect(views.first.preset.profile.animate, isTrue);
    expect(feed.stateOf(0).value.playing, isTrue);
    expect(feed.stateOf(2).value.visible, isFalse);
  });

  testWidgets('a page that holds a player shows it', (tester) async {
    final backend = FakePlayerBackend();
    final pool = PlayerPool(backend: backend);
    addTearDown(pool.dispose);
    final feed = FeedController(
      policy: const FeedPolicy.pager(),
      pool: pool,
      presetOf: preset,
    );
    addTearDown(feed.dispose);
    await pump(
      tester,
      FeedScope(
        controller: feed,
        child: PageView.builder(
          itemCount: 5,
          itemBuilder: (context, index) => FeedSlot(
            index: index,
            item: _item(index),
            child: const FeedClip(poster: Text('poster')),
          ),
        ),
      ),
    );

    expect(find.byType(PlayerView), findsOneWidget);
    expect(pool.soundOwner, _key(0));
  });

  testWidgets('a clip laid out far ahead holds no decoder', (tester) async {
    final feed = FeedController(
      presetOf: preset,
      policy: const FeedPolicy.list(heavyUnloadViewports: 1),
    );
    addTearDown(feed.dispose);
    await pump(
      tester,
      FeedScope(
        controller: feed,
        child: ListView.builder(
          cacheExtent: 3000,
          itemCount: 10,
          itemBuilder: (context, index) => FeedSlot(
            index: index,
            item: _item(index),
            child: SizedBox(
              height: 500,
              child: FeedClip(poster: index == 4 ? const Text('far') : null),
            ),
          ),
        ),
      ),
    );

    // Item 4 starts at 2000: three viewports below the 500-high one.
    expect(feed.stateOf(4).value.released, isTrue);
    expect(find.text('far', skipOffstage: false), findsOneWidget);
    expect(feed.stateOf(1).value.released, isFalse);
  });
}
