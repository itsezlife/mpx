import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_ui/mpx_ui.dart';

import 'viewer_harness.dart';

const _android = ViewerPolicy.$Android;
const _ios = ViewerPolicy.$IOS;

// The pictures rest 400 x 300 in the 400 x 800 viewer; at 3x one is
// 1200 x 900 and pans 400 px either way across and 50 px up and down.
const _centre = Offset(200, 400);

Future<void> _doubleTap(WidgetTester tester, Offset at) async {
  await tester.tapAt(at);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tapAt(at);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 251));
}

// A slow drag: claimed past the slop (swallowed), then moved by [by] in
// steps, so the release has no velocity.
Future<TestGesture> _drag(
  WidgetTester tester,
  Offset by, {
  Offset from = _centre,
}) async {
  final gesture = await tester.startGesture(from);
  final claim = Offset(by.dx.sign * 20, by.dy.sign * 20);
  await gesture.moveBy(claim);
  await tester.pump();
  const steps = 10;
  for (var i = 0; i < steps; i++) {
    await gesture.moveBy(by / steps.toDouble());
    await tester.pump();
  }
  return gesture;
}

Future<void> _release(WidgetTester tester, TestGesture gesture) async {
  await gesture.up();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  group('zoom', () {
    testWidgets('double tap near an edge lands on the clamped target', (
      tester,
    ) async {
      final harness = ViewerHarness();
      await harness.pump(tester);

      await _doubleTap(tester, const Offset(200, 700));
      final page = harness.page(tester);
      expect(page.zoom, 3);
      // 300 below the centre would pan to -600; the picture stops 50 out.
      expect(page.pan, const Offset(0, -50));
    });

    testWidgets('Android: a pinch zooms around where it started', (
      tester,
    ) async {
      final harness = ViewerHarness();
      await harness.pump(tester);

      final a = await tester.startGesture(const Offset(150, 400));
      final b = await tester.startGesture(const Offset(250, 400));
      await tester.pump();
      // Apart to twice the span, and both 60 px down: no two-finger pan.
      await a.moveTo(const Offset(100, 460));
      await b.moveTo(const Offset(300, 460));
      await tester.pump();
      final page = harness.page(tester);
      expect(page.zoom, closeTo(2, 1e-9));
      expect(page.pan, Offset.zero);
      await a.up();
      await b.up();
      await tester.pump(const Duration(milliseconds: 300));
    });

    testWidgets('iOS: a pinch follows the fingers and bounces past 3x', (
      tester,
    ) async {
      final harness = ViewerHarness();
      await harness.pump(tester, policy: _ios);

      final a = await tester.startGesture(const Offset(150, 400));
      final b = await tester.startGesture(const Offset(250, 400));
      await tester.pump();
      await a.moveTo(const Offset(100, 410));
      await b.moveTo(const Offset(300, 410));
      await tester.pump();
      final page = harness.page(tester);
      expect(page.zoom, closeTo(2, 1e-9));
      // The picture is shorter than the page: its vertical pan is banded.
      expect(page.pan.dy, closeTo(10 * _ios.overPanDamping, 1e-9));

      // Six times the span: past the largest zoom, it follows less.
      await a.moveTo(const Offset(-100, 410));
      await b.moveTo(const Offset(500, 410));
      await tester.pump();
      final max = _ios.maxZoomFor(fittedRect.size, viewerSize);
      expect(page.zoom, greaterThan(max));
      expect(page.zoom, lessThan(6));
      await a.up();
      await b.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(page.zoom, closeTo(max, 1e-9));
    });

    testWidgets('a zoomed fling runs on and stops at the bounds', (
      tester,
    ) async {
      final harness = ViewerHarness();
      await harness.pump(tester);
      await _doubleTap(tester, _centre);

      await tester.flingFrom(_centre, const Offset(-100, 0), 3000);
      await tester.pump();
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final page = harness.page(tester);
      expect(page.pan.dx, -400);
      expect(page.zoom, 3);
      expect(harness.state(tester).index, 0);
    });

    testWidgets('desktop: a pan of a zoomed picture has no inertia', (
      tester,
    ) async {
      final harness = ViewerHarness();
      await harness.pump(tester, policy: _android.copyWith(zoomFling: false));
      await _doubleTap(tester, _centre);

      await tester.flingFrom(_centre, const Offset(-100, 0), 3000);
      await tester.pump(const Duration(seconds: 1));
      // The slop is swallowed: 90 px followed, no more.
      expect(harness.page(tester).pan.dx, closeTo(-90, 1e-9));
    });

    testWidgets('a pinch is refused while a neighbour shows', (tester) async {
      final harness = ViewerHarness();
      await harness.pump(tester);

      final a = await tester.startGesture(const Offset(300, 400));
      await a.moveBy(const Offset(-20, 0));
      await tester.pump();
      await a.moveBy(const Offset(-60, 0));
      await tester.pump();
      final b = await tester.startGesture(const Offset(100, 400));
      await b.moveBy(const Offset(-80, 0));
      await tester.pump();
      expect(harness.pageAt(tester, 0).zoom, 1);
      await a.up();
      await b.up();
      await tester.pump(const Duration(milliseconds: 400));
    });
  });

  group('the edge hand-off', () {
    Future<ViewerHarness> zoomedOnSecond(
      WidgetTester tester, {
      ViewerPolicy policy = _android,
    }) async {
      final controller = ViewerController();
      addTearDown(controller.dispose);
      final harness = ViewerHarness();
      await harness.pump(tester, policy: policy, controller: controller);
      controller.jumpTo(1);
      await tester.pump();
      await _doubleTap(tester, _centre);
      expect(harness.page(tester).zoom, 3);
      return harness;
    }

    testWidgets(
      'past the edge by a third of a page the previous page comes in; the '
      'page left goes back to rest',
      (tester) async {
        final harness = await zoomedOnSecond(tester);

        // 400 to the picture's left edge, then 160 on to the pager.
        final gesture = await _drag(tester, const Offset(560, 0));
        expect(harness.pageAt(tester, 1).pan.dx, 400);
        await _release(tester, gesture);

        expect(harness.state(tester).index, 0);
        expect(harness.pageAt(tester, 1).zoom, 1);
      },
    );

    testWidgets('by less it goes back, still zoomed at its edge', (
      tester,
    ) async {
      final harness = await zoomedOnSecond(tester);

      final gesture = await _drag(tester, const Offset(480, 0));
      await _release(tester, gesture);

      expect(harness.state(tester).index, 1);
      expect(harness.page(tester).zoom, 3);
      expect(harness.page(tester).pan.dx, 400);
    });

    testWidgets('Android: a fast flick past the edge pages by distance only', (
      tester,
    ) async {
      final harness = await zoomedOnSecond(tester);

      final gesture = await _drag(tester, const Offset(380, 0));
      await gesture.up();
      await tester.pump();
      // At the edge now; a short fast flick hands 60 px on.
      await tester.flingFrom(_centre, const Offset(80, 0), 3000);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(harness.state(tester).index, 1);
    });

    testWidgets('iOS: the flick counts once the picture is pinned', (
      tester,
    ) async {
      final harness = await zoomedOnSecond(tester, policy: _ios);

      final gesture = await _drag(tester, const Offset(380, 0));
      await gesture.up();
      await tester.pump(const Duration(seconds: 2));
      await tester.flingFrom(_centre, const Offset(80, 0), 3000);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(harness.state(tester).index, 0);
    });

    testWidgets('toward no page the picture follows a third, then snaps back', (
      tester,
    ) async {
      final harness = ViewerHarness();
      await harness.pump(tester);
      await _doubleTap(tester, _centre);

      final gesture = await _drag(tester, const Offset(490, 0));
      // 400 free, 90 more at a third.
      expect(harness.page(tester).pan.dx, closeTo(430, 1e-9));
      await _release(tester, gesture);
      expect(harness.page(tester).pan.dx, 400);
      expect(harness.state(tester).index, 0);
    });

    testWidgets('a vertical pan of a zoomed picture never dismisses', (
      tester,
    ) async {
      final harness = ViewerHarness();
      await harness.pump(tester);
      await _doubleTap(tester, _centre);

      final gesture = await _drag(tester, const Offset(0, 300));
      expect(harness.state(tester).dragOffset, 0);
      await _release(tester, gesture);
      expect(harness.closed, 0);
      expect(harness.page(tester).pan.dy, 50);
    });

    testWidgets('a picture zoomed by a pinch pans on with the finger left', (
      tester,
    ) async {
      final harness = ViewerHarness();
      await harness.pump(tester);

      final a = await tester.startGesture(const Offset(150, 400));
      final b = await tester.startGesture(const Offset(250, 400));
      await tester.pump();
      await a.moveTo(const Offset(50, 400));
      await b.moveTo(const Offset(350, 400));
      await tester.pump();
      expect(harness.page(tester).zoom, closeTo(3, 1e-9));
      await b.up();
      await tester.pump();
      await a.moveBy(const Offset(-100, 0));
      await tester.pump();
      expect(harness.page(tester).pan.dx, closeTo(-100, 1e-9));
      await a.up();
      await tester.pump(const Duration(milliseconds: 400));
    });
  });
}
