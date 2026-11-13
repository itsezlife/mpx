import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_player/testing.dart';

const _viewport = Size(400, 500);

MediaKey _key(int index) => MediaKey.remote('clip-$index');

FeedItem _item(int index) => FeedItem(_key(index));

void main() {
  late FeedController controller;

  setUp(() => controller = FeedController(itemCount: 40, itemOf: _item));
  tearDown(() => controller.dispose());

  Future<void> pump(WidgetTester tester, Widget scrollable) async {
    tester.view.physicalSize = _viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: FeedScope(controller: controller, child: scrollable),
      ),
    );
    await tester.pump();
  }

  Widget slot(int index, {double? width, double? height}) => FeedSlot(
    index: index,
    item: _item(index),
    child: SizedBox(width: width, height: height),
  );

  /// The controller's decisions are the planner's for [fractions] (what the
  /// layout shows, worked out by hand) and [centres].
  void expectPlannerDecisions(
    Map<int, double> fractions, {
    Map<int, double> centres = const {},
    FeedScrollDirection direction = FeedScrollDirection.forward,
  }) {
    for (var index = 0; index < 40; index++) {
      expect(
        controller.stateOf(index).value.fraction,
        closeTo(fractions[index] ?? 0, 1e-9),
        reason: 'fraction of $index',
      );
    }
    final plan = const FeedListPlanner(FeedPolicy.list()).plan(
      FeedListViewport(
        itemCount: 40,
        visible: fractions,
        centreDistances: centres,
        direction: direction,
      ),
      _item,
    );
    expect(controller.inView.value, plan.inView);
    for (var index = 0; index < 40; index++) {
      final state = controller.stateOf(index).value;
      expect(
        state.playing,
        plan.playing.contains(index),
        reason: 'playing of $index',
      );
      expect(state.preload, plan.preloads[index], reason: 'preload $index');
    }
  }

  testWidgets('a list with mixed extents', (tester) async {
    const extents = [100.0, 300.0, 150.0, 200.0, 250.0];
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await pump(
      tester,
      ListView.builder(
        controller: scroll,
        itemCount: 40,
        itemBuilder: (context, index) =>
            slot(index, height: extents[index % extents.length]),
      ),
    );

    // Items 0..4 sit at 0, 100, 400, 550, 750; 250..750 shows half of 1 and
    // all of 2 and 3.
    scroll.jumpTo(250);
    await tester.pump();

    expectPlannerDecisions(
      {1: 0.5, 2: 1, 3: 1},
      centres: {1: 250, 2: 25, 3: 150},
    );
    expect(controller.inView.value, 2);
  });

  testWidgets('a sliver list under a header in a custom scroll view', (
    tester,
  ) async {
    await pump(
      tester,
      CustomScrollView(
        slivers: [
          const SliverToBoxAdapter(child: SizedBox(height: 120)),
          SliverList.builder(
            itemCount: 40,
            itemBuilder: (context, index) => slot(index, height: 200),
          ),
        ],
      ),
    );

    // Item 0 at 120..320, item 1 at 320..520 (180 of 200 show).
    expectPlannerDecisions({0: 1, 1: 0.9}, centres: {0: 30, 1: 170});
  });

  testWidgets('a horizontal list', (tester) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await pump(
      tester,
      ListView.builder(
        controller: scroll,
        scrollDirection: Axis.horizontal,
        itemCount: 40,
        itemBuilder: (context, index) => slot(index, width: 150),
      ),
    );

    scroll.jumpTo(100);
    await tester.pump();

    // 100..500 shows a third of 0 and 3, all of 1 and 2.
    expectPlannerDecisions(
      {0: 1 / 3, 1: 1, 2: 1, 3: 1 / 3},
      centres: {0: 175, 1: 75, 2: 75, 3: 225},
    );
  });

  testWidgets('a grid', (tester) async {
    await pump(
      tester,
      GridView.builder(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
        ),
        itemCount: 40,
        itemBuilder: (context, index) => slot(index),
      ),
    );

    // 200 x 200 tiles; the third row shows half. The viewport's centre is
    // (200, 250).
    expectPlannerDecisions(
      {0: 1, 1: 1, 2: 1, 3: 1, 4: 0.5, 5: 0.5},
      centres: {
        0: 180.27756377319946,
        1: 180.27756377319946,
        2: 111.80339887498948,
        3: 111.80339887498948,
        4: 269.2582403567252,
        5: 269.2582403567252,
      },
    );
    expect(controller.inView.value, 2);
  });

  testWidgets('a horizontal list inside a vertical one is clipped by both', (
    tester,
  ) async {
    final outer = ScrollController();
    final inner = ScrollController();
    addTearDown(outer.dispose);
    addTearDown(inner.dispose);
    await pump(
      tester,
      ListView(
        controller: outer,
        children: [
          const SizedBox(height: 100),
          SizedBox(
            height: 200,
            child: ListView.builder(
              controller: inner,
              scrollDirection: Axis.horizontal,
              itemCount: 40,
              itemBuilder: (context, index) => slot(index, width: 150),
            ),
          ),
          const SizedBox(height: 2000),
        ],
      ),
    );
    expectPlannerDecisions(
      {0: 1, 1: 1, 2: 2 / 3},
      centres: {0: 125, 1: 25, 2: 175},
    );

    // The row at 100..300 shows from 200: half of it. Inside, 100..500
    // shows a third of 0 and 3.
    outer.jumpTo(200);
    await tester.pump();
    inner.jumpTo(100);
    await tester.pump();

    expectPlannerDecisions(
      {0: 1 / 6, 1: 0.5, 2: 0.5, 3: 1 / 6},
      centres: {0: 225, 1: 75, 2: 75, 3: 225},
    );

    outer.jumpTo(400);
    await tester.pump();
    expectPlannerDecisions(const {});
  });

  testWidgets('a cell kept alive off screen is hidden, and comes back', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await pump(
      tester,
      ListView.builder(
        controller: scroll,
        itemCount: 40,
        itemBuilder: (context, index) =>
            _KeptAlive(keep: index == 0, child: slot(index, height: 200)),
      ),
    );
    expect(controller.stateOf(0).value.playing, isTrue);

    scroll.jumpTo(2000);
    await tester.pump();
    expect(controller.stateOf(0).value.visible, isFalse);
    expect(controller.stateOf(0).value.playing, isFalse);

    scroll.jumpTo(0);
    await tester.pump();
    expect(controller.stateOf(0).value.fraction, 1);
  });

  testWidgets('a recycled slot moves to its new index', (tester) async {
    var index = 3;
    late StateSetter setIndex;
    await pump(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          setIndex = setState;
          return Column(children: [slot(index, width: 100, height: 100)]);
        },
      ),
    );
    expect(controller.stateOf(3).value.fraction, 1);

    setIndex(() => index = 9);
    await tester.pump();
    await tester.pump();

    expect(controller.stateOf(3).value.visible, isFalse);
    expect(controller.stateOf(9).value.fraction, 1);
    expect(controller.inView.value, 9);
  });

  testWidgets('a slot reads its decision below it', (tester) async {
    final seen = <bool>[];
    await pump(
      tester,
      ListView(
        children: [
          FeedSlot(
            index: 0,
            item: _item(0),
            child: Builder(
              builder: (context) => ValueListenableBuilder<FeedItemState>(
                valueListenable: FeedSlot.of(context).state,
                builder: (context, state, _) {
                  seen.add(state.playing);
                  return const SizedBox(height: 100);
                },
              ),
            ),
          ),
        ],
      ),
    );

    expect(seen.last, isTrue);
  });

  testWidgets('any pager: the most visible page plays', (tester) async {
    final backend = FakePlayerBackend();
    final pool = PlayerPool(backend: backend);
    addTearDown(pool.dispose);
    final pager = FeedController(
      policy: const FeedPolicy.pager(),
      pool: pool,
      itemCount: 10,
      itemOf: _item,
    );
    addTearDown(pager.dispose);
    tester.view.physicalSize = _viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: PageView.builder(
          scrollDirection: Axis.vertical,
          itemCount: 10,
          itemBuilder: (context, index) => FeedSlot(
            index: index,
            controller: pager,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(pool.soundOwner, _key(0));

    // Held mid-swipe past the half: page 1 shows more and plays.
    final gesture = await tester.startGesture(const Offset(200, 250));
    await gesture.moveBy(const Offset(0, -20));
    await gesture.moveBy(const Offset(0, -300));
    await tester.pump();
    expect(pager.stateOf(1).value.fraction, greaterThan(0.5));
    expect(pager.inView.value, 1);
    expect(pool.soundOwner, _key(1));
    expect(pager.stateOf(1).value.lease, isNotNull);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(pager.stateOf(1).value.fraction, 1);
    expect(pager.inView.value, 1);
  });
}

class _KeptAlive extends StatefulWidget {
  const _KeptAlive({required this.keep, required this.child});

  final bool keep;
  final Widget child;

  @override
  State<_KeptAlive> createState() => _KeptAliveState();
}

class _KeptAliveState extends State<_KeptAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => widget.keep;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
