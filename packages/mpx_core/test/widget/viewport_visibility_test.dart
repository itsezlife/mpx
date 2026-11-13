import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';

void main() {
  // A 400 x 800 screen.
  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      Directionality(textDirection: TextDirection.ltr, child: child),
    );
  }

  RenderBox boxOf(WidgetTester tester, Key key) =>
      tester.renderObject<RenderBox>(find.byKey(key, skipOffstage: false));

  testWidgets('a box with no viewport around it shows whole, unclipped', (
    tester,
  ) async {
    const key = ValueKey('box');
    await pump(
      tester,
      const Align(
        alignment: Alignment.topLeft,
        child: SizedBox(key: key, width: 100, height: 50),
      ),
    );

    final seen = ViewportVisibility.of(boxOf(tester, key));
    expect(seen.rect, const Rect.fromLTWH(0, 0, 100, 50));
    expect(seen.clip, isNull);
    expect(seen.fraction, 1);
    expect(seen.viewportsAway, 0);
  });

  testWidgets('a list clips a box it scrolled half away', (tester) async {
    final list = ScrollController();
    addTearDown(list.dispose);
    await pump(
      tester,
      ListView(
        controller: list,
        children: [
          for (var i = 0; i < 10; i++) SizedBox(key: ValueKey(i), height: 200),
        ],
      ),
    );
    list.jumpTo(100);
    await tester.pump();

    final seen = ViewportVisibility.of(boxOf(tester, const ValueKey(0)));
    expect(seen.rect, const Rect.fromLTWH(0, -100, 400, 200));
    expect(seen.clip, const Rect.fromLTWH(0, 0, 400, 800));
    expect(seen.fraction, 0.5);
    expect(seen.shows, isTrue);
    // Centre at y 0, the viewport's at y 400.
    expect(seen.centreDistance, 400);
  });

  testWidgets(
    'a box in a horizontal list in a vertical one is clipped by both',
    (tester) async {
      final outer = ScrollController();
      addTearDown(outer.dispose);
      await pump(
        tester,
        ListView(
          controller: outer,
          children: [
            SizedBox(
              height: 200,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: const [
                  SizedBox(width: 300),
                  SizedBox(key: ValueKey('inner'), width: 200),
                ],
              ),
            ),
            const SizedBox(height: 2000),
          ],
        ),
      );
      outer.jumpTo(100);
      await tester.pump();

      // x 300..500 shows 300..400; y -100..100 shows 0..100: a quarter.
      final seen = ViewportVisibility.of(
        boxOf(tester, const ValueKey('inner')),
      );
      expect(seen.clip, const Rect.fromLTWH(0, 0, 400, 100));
      expect(seen.fraction, closeTo(0.25, 1e-9));
    },
  );

  testWidgets('a box laid out beyond the viewport is that many extents away', (
    tester,
  ) async {
    await pump(
      tester,
      ListView(
        cacheExtent: 4000,
        children: [
          for (var i = 0; i < 20; i++) SizedBox(key: ValueKey(i), height: 400),
        ],
      ),
    );

    // Item 6 starts at 2400: 1600 below the 800-high viewport.
    final seen = ViewportVisibility.of(boxOf(tester, const ValueKey(6)));
    expect(seen.fraction, 0);
    expect(seen.shows, isFalse);
    expect(seen.viewportsAway, 2);
  });

  testWidgets('a box its parent does not paint is out of every view', (
    tester,
  ) async {
    const key = ValueKey('offstage');
    await pump(
      tester,
      const Offstage(child: SizedBox(key: key, width: 10, height: 10)),
    );

    final seen = ViewportVisibility.of(
      tester.renderObject<RenderBox>(find.byKey(key, skipOffstage: false)),
    );
    expect(seen.shows, isFalse);
  });
}
