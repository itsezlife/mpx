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

    for (final (name, policy) in [('Android', _android), ('iOS', _ios)]) {
      testWidgets('$name: a double tap back lands exactly at rest', (
        tester,
      ) async {
        final harness = ViewerHarness();
        await harness.pump(tester, policy: policy);
        await _doubleTap(tester, const Offset(130, 370));
        await _doubleTap(tester, const Offset(130, 370));
        await tester.pump(const Duration(milliseconds: 100));

        final page = harness.page(tester);
        expect(page.zoom, 1);
        expect(page.pan, Offset.zero);
        expect(page.isZoomed, isFalse);
      });
    }

    testWidgets('a vertical drag that starts while the zoom goes back to rest '
        'dismisses, and the zoom still lands', (tester) async {
      final harness = ViewerHarness();
      await harness.pump(tester);
      await _doubleTap(tester, const Offset(130, 370));
      // The second double tap, then a touch 100 ms into the settle.
      await tester.tapAt(_centre);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(_centre);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final gesture = await _drag(tester, const Offset(0, 100));
      expect(harness.state(tester).dragOffset, greaterThan(0));
      await _release(tester, gesture);
      final page = harness.page(tester);
      expect(page.zoom, 1);
      expect(page.pan, Offset.zero);
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

    testWidgets(
      'Android: a pinch released past 3x settles at 3x around its start, '
      'and the finger lifted last throws nothing',
      (tester) async {
        final harness = ViewerHarness();
        await harness.pump(tester);

        // Off-centre: the pinch starts at (100, 350), 100 left of and 50
        // above the centre.
        var t = Duration.zero;
        Future<void> step(TestGesture finger, Offset by) async {
          t += const Duration(milliseconds: 8);
          await finger.moveBy(by, timeStamp: t);
          await tester.pump(const Duration(milliseconds: 8));
        }

        final a = await tester.startGesture(const Offset(60, 350));
        final b = await tester.startGesture(const Offset(140, 350));
        await tester.pump();
        // Apart to four times the span, past the largest zoom.
        for (var i = 0; i < 8; i++) {
          await step(a, const Offset(-15, 0));
          await step(b, const Offset(15, 0));
        }
        final page = harness.page(tester);
        expect(page.zoom, closeTo(4, 1e-9));

        // One finger lifts, the other keeps moving fast sideways and lifts.
        await b.up(timeStamp: t);
        await tester.pump();
        for (var i = 0; i < 4; i++) {
          await step(a, const Offset(-40, 0));
        }
        await a.up(timeStamp: t);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        // The start point (-100, -50) from the centre keeps its place at
        // 3x: pan (200, 100), the vertical clamped to the 50 the picture
        // has.
        expect(page.zoom, closeTo(3, 1e-9));
        expect(page.pan.dx, closeTo(200, 1e-6));
        expect(page.pan.dy, closeTo(50, 1e-6));
        // Nothing moves on after the settle.
        await tester.pump(const Duration(seconds: 1));
        expect(page.pan.dx, closeTo(200, 1e-6));
        expect(page.pan.dy, closeTo(50, 1e-6));
        expect(harness.state(tester).index, 0);
      },
    );

    testWidgets('Android: a pinch released below 1x goes back to rest', (
      tester,
    ) async {
      final harness = ViewerHarness();
      await harness.pump(tester);
      await _doubleTap(tester, const Offset(100, 350));
      final page = harness.page(tester);
      expect(page.zoom, 3);

      final a = await tester.startGesture(const Offset(0, 350));
      final b = await tester.startGesture(const Offset(200, 350));
      await tester.pump();
      // Together to a tenth of the span: 0.3x.
      await a.moveTo(const Offset(90, 350));
      await b.moveTo(const Offset(110, 350));
      await tester.pump();
      expect(page.zoom, lessThan(1));
      await b.up();
      await tester.pump();
      await a.moveBy(const Offset(-60, 0));
      await tester.pump();
      await a.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(page.zoom, 1);
      expect(page.pan, Offset.zero);
      await tester.pump(const Duration(seconds: 1));
      expect(page.pan, Offset.zero);
      expect(harness.state(tester).index, 0);
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

  group('dismiss', () {
    testWidgets(
      'Android: 30 px twice as vertical as wide dismisses, and the pager '
      'never moves after',
      (tester) async {
        final harness = ViewerHarness();
        await harness.pump(tester);

        final gesture = await tester.startGesture(_centre);
        await gesture.moveBy(const Offset(-14, 30));
        await tester.pump();
        await gesture.moveBy(const Offset(-200, 40));
        await tester.pump();
        expect(harness.state(tester).dragOffset, 40);
        expect(tester.getCenter(find.byType(ViewerPhotoPage)).dx, 200);
        await gesture.up();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(harness.closed, 0);
        expect(harness.state(tester).index, 0);
      },
    );

    testWidgets('Android: a drag that is not twice as vertical pages', (
      tester,
    ) async {
      final harness = ViewerHarness();
      await harness.pump(tester);

      final gesture = await tester.startGesture(_centre);
      await gesture.moveBy(const Offset(-20, 6));
      await tester.pump();
      await gesture.moveBy(const Offset(-150, 150));
      await tester.pump();
      expect(harness.state(tester).dragOffset, 0);
      await _release(tester, gesture);
      expect(harness.state(tester).index, 1);
    });

    testWidgets('Android: a fast short flick does not close', (tester) async {
      final harness = ViewerHarness();
      await harness.pump(tester);

      await tester.flingFrom(_centre, const Offset(0, 80), 3000);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(harness.closed, 0);
      expect(harness.state(tester).dragOffset, 0);
    });

    for (final (name, policy, distance) in [
      ('Android', _android, 160.0),
      ('iOS', _ios, 210.0),
    ]) {
      for (final sign in [1.0, -1.0]) {
        testWidgets(
          '$name: past its fraction ${sign > 0 ? 'down' : 'up'} closes',
          (tester) async {
            final harness = ViewerHarness();
            await harness.pump(tester, policy: policy);

            final gesture = await _drag(tester, Offset(0, sign * distance));
            await gesture.up();
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 400));
            expect(harness.closed, 1);
          },
        );
      }
    }

    testWidgets('iOS: the background is gone 80 pt into the drag', (
      tester,
    ) async {
      final harness = ViewerHarness();
      await harness.pump(tester, policy: _ios);

      final gesture = await _drag(tester, const Offset(0, 40));
      expect(harness.state(tester).backgroundOpacity, closeTo(0.5, 1e-9));
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();
      expect(harness.state(tester).backgroundOpacity, 0);
      await _release(tester, gesture);
      expect(harness.closed, 0);
      expect(harness.state(tester).backgroundOpacity, 1);
    });

    testWidgets('a dismiss drag hides the chrome and leaves it hidden', (
      tester,
    ) async {
      final harness = ViewerHarness();
      await harness.pump(tester);
      expect(harness.state(tester).controlsVisible, isTrue);

      final gesture = await _drag(tester, const Offset(0, 60));
      expect(harness.state(tester).controlsVisible, isFalse);
      await _release(tester, gesture);
      expect(harness.state(tester).controlsVisible, isFalse);
    });
  });
}
