import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_ui/mpx_ui.dart';

import 'viewer_harness.dart';

void main() {
  // Pictures of 1200 x 900 at the strip's 56 high are 74.67 wide.
  const grown = 1200 * (56 / 900);
  const base = 42.0;

  Finder thumb(int index) => find.byKey(ValueKey(('mpx-viewer-thumb', index)));
  double widthOf(WidgetTester tester, int index) =>
      tester.getSize(thumb(index)).width;

  Future<ViewerHarness> open(WidgetTester tester, {int count = 6}) async {
    final harness = ViewerHarness(count: count);
    await harness.pump(tester, chrome: const ViewerChrome(thumbnails: true));
    await tester.pump(const Duration(milliseconds: 400));
    return harness;
  }

  testWidgets('the item on show is wide, the others the base', (tester) async {
    await open(tester);

    expect(widthOf(tester, 0), closeTo(grown, 0.01));
    expect(widthOf(tester, 1), base);
    expect(widthOf(tester, 2), base);
  });

  testWidgets('the strip is in the middle of the item on show', (tester) async {
    await open(tester);
    final strip = tester.getRect(
      find.byKey(const ValueKey('mpx-viewer-strip')),
    );

    expect(tester.getCenter(thumb(0)).dx, closeTo(strip.center.dx, 0.5));
  });

  testWidgets('it follows a page swipe as the finger moves: the item that '
      'goes shrinks as the next one grows', (tester) async {
    await open(tester);

    final gesture = await tester.startGesture(const Offset(200, 400));
    await gesture.moveBy(const Offset(-30, 0));
    await gesture.moveBy(const Offset(-120, 0));
    await tester.pump();

    expect(widthOf(tester, 0), lessThan(grown - 5));
    expect(widthOf(tester, 0), greaterThan(base));
    expect(widthOf(tester, 1), greaterThan(base + 5));
    expect(widthOf(tester, 1), lessThan(grown));

    // Past half a page, it settles on the next one.
    await gesture.moveBy(const Offset(-120, 0));
    await gesture.up();
    // A ticker's first frame is its start: the settle runs on the next.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(widthOf(tester, 1), closeTo(grown, 0.01));
    expect(widthOf(tester, 0), base);
  });

  testWidgets('a tap on a thumbnail moves the focus in 200 ms, easing out', (
    tester,
  ) async {
    final harness = await open(tester);

    await tester.tap(thumb(3));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 60));

    // On its way: grown by part of the way, the old one shrunk by part.
    expect(widthOf(tester, 3), greaterThan(base + 1));
    expect(widthOf(tester, 3), lessThan(grown - 1));
    expect(harness.state(tester).index, 3);

    await tester.pump(const Duration(milliseconds: 300));
    expect(widthOf(tester, 3), closeTo(grown, 0.01));
    expect(widthOf(tester, 0), base);
  });

  testWidgets('a drag along the strip scrubs through the items and settles '
      'on the one it stops at', (tester) async {
    final harness = await open(tester);
    final strip = find.byKey(const ValueKey('mpx-viewer-strip'));

    // Two thumbnails to the left of the finger: two items on.
    await tester.dragFrom(
      tester.getCenter(strip),
      const Offset(-2 * (base + 1) - 20, 0),
    );
    await tester.pump(const Duration(milliseconds: 500));

    expect(harness.state(tester).index, 2);
    expect(widthOf(tester, 2), closeTo(grown, 0.01));
  });

  testWidgets('the strip does not go past the first item', (tester) async {
    final harness = await open(tester);
    final strip = find.byKey(const ValueKey('mpx-viewer-strip'));

    await tester.dragFrom(tester.getCenter(strip), const Offset(300, 0));
    await tester.pump(const Duration(milliseconds: 500));

    expect(harness.state(tester).index, 0);
  });

  group('a fling', () {
    testWidgets('carries a long strip on past the finger and settles on an '
        'item', (tester) async {
      final harness = await open(tester, count: 30);
      final strip = find.byKey(const ValueKey('mpx-viewer-strip'));

      await tester.fling(strip, const Offset(-100, 0), 3000);
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));

      // A drag of 100 px is two items; the fling went much further.
      final index = harness.state(tester).index;
      expect(index, greaterThan(6));
      expect(widthOf(tester, index), closeTo(grown, 0.01));
    });

    testWidgets('does not carry a short one: under ten items a fling is a '
        'drag', (tester) async {
      final harness = await open(tester, count: 6);
      final strip = find.byKey(const ValueKey('mpx-viewer-strip'));

      await tester.fling(strip, const Offset(-100, 0), 3000);
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));

      expect(harness.state(tester).index, lessThanOrEqualTo(3));
    });

    testWidgets('stops at the end of the strip', (tester) async {
      final harness = await open(tester, count: 12);
      final strip = find.byKey(const ValueKey('mpx-viewer-strip'));

      await tester.fling(strip, const Offset(-300, 0), 8000);
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));

      expect(harness.state(tester).index, 11);
    });
  });

  testWidgets('the strip comes in on its own, 200 ms, as the chrome does', (
    tester,
  ) async {
    final harness = ViewerHarness(count: 4);
    await harness.pump(
      tester,
      chrome: const ViewerChrome(thumbnails: true),
      open: false,
    );
    final fade = find.byKey(const ValueKey('mpx-viewer-strip-fade'));
    double opacity() => tester.widget<Opacity>(fade).opacity;

    expect(opacity(), 0);
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 80));
    expect(opacity(), inExclusiveRange(0.2, 0.8));

    await tester.pump(const Duration(milliseconds: 300));
    expect(opacity(), 1);
  });
}
