import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_ui/mpx_ui.dart';

import 'viewer_harness.dart';

const _android = ViewerPolicy.$Android;

void main() {
  group('policy', () {
    test('the Android reference values', () {
      expect(_android.openDuration, const Duration(milliseconds: 200));
      expect(_android.closeDuration, const Duration(milliseconds: 200));
      expect(_android.backdropScale, 0.1);
      expect(_android.dismissFraction, 1 / 6);
      expect(_android.dismissDownOnly, isTrue);
      expect(_android.backgroundOpacityFloor, 127 / 255);
      expect(_android.settleDuration, const Duration(milliseconds: 250));
      expect(_android.doubleTapZoom, 3);
      expect(_android.minZoom, 1);
      expect(_android.maxZoom, 3);
      expect(_android.pageGap, 15);
      expect(_android.videoAutoHide, const Duration(milliseconds: 3000));
    });

    test('a dismiss drag starts at 30 px, twice as vertical as wide', () {
      expect(_android.startsDismiss(0, 29), isFalse);
      expect(_android.startsDismiss(0, 30), isTrue);
      expect(_android.startsDismiss(16, 30), isFalse);
      expect(_android.startsDismiss(0, -40), isFalse);
    });

    test('dismisses past a sixth of the height, downward only', () {
      expect(_android.dismisses(133, 800), isFalse);
      expect(_android.dismisses(134, 800), isTrue);
      expect(_android.dismisses(-400, 800), isFalse);
    });

    test('the background fades over a quarter of the width to 127', () {
      expect(_android.backgroundOpacityAt(0, 400), 1);
      expect(_android.backgroundOpacityAt(50, 400), 0.5 + 0.0);
      expect(_android.backgroundOpacityAt(400, 400), 127 / 255);
    });

    test('a pinch settles within 1x to 3x', () {
      expect(_android.settleZoom(0.4), 1);
      expect(_android.settleZoom(2), 2);
      expect(_android.settleZoom(5), 3);
    });
  });

  group('open', () {
    testWidgets('morphs from the origin to the fitted picture in 200 ms', (
      tester,
    ) async {
      final harness = ViewerHarness();
      await harness.pump(tester, open: false);

      expect(harness.morphRect(tester), originRect);
      expect(harness.bridge.hidden, {0});
      expect(harness.state(tester).backgroundOpacity, 0);

      await tester.pump(const Duration(milliseconds: 100));
      final halfway = harness.morphRect(tester);
      expect(halfway.top, inExclusiveRange(fittedRect.top, originRect.top));
      expect(harness.state(tester).backgroundOpacity, inExclusiveRange(0, 1));

      await tester.pump(const Duration(milliseconds: 101));
      expect(harness.state(tester).isOpen, isTrue);
      expect(harness.state(tester).backgroundOpacity, 1);
      expect(tester.getRect(find.byType(ViewerPhotoPage)).height, 800);
      expect(harness.backdrop.last, closeTo(1.1, 1e-9));
    });

    testWidgets('asks the source around the item it opens on', (tester) async {
      final harness = ViewerHarness();
      await harness.pump(tester);

      expect(harness.source.requests, [0]);
    });

    testWidgets('without an origin it fades in where it rests', (tester) async {
      final harness = ViewerHarness();
      harness.bridge.origins.clear();
      await harness.pump(tester, open: false);

      expect(harness.morphRect(tester), fittedRect);
    });
  });

  group('dismiss', () {
    Future<TestGesture> dragDown(WidgetTester tester, double after) async {
      final gesture = await tester.startGesture(const Offset(200, 400));
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();
      await gesture.moveBy(const Offset(0, 30));
      await tester.pump();
      await gesture.moveBy(Offset(0, after));
      await tester.pump();
      return gesture;
    }

    testWidgets('a drag below a sixth of the height springs back', (
      tester,
    ) async {
      final harness = ViewerHarness();
      await harness.pump(tester);

      final gesture = await dragDown(tester, 100);
      expect(harness.state(tester).dragOffset, 100);
      expect(harness.backdrop.last, lessThan(1.1));

      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 251));

      expect(harness.state(tester).dragOffset, 0);
      expect(harness.state(tester).isOpen, isTrue);
      expect(harness.closed, 0);
    });

    testWidgets('the background never drops below its floor', (tester) async {
      final harness = ViewerHarness();
      await harness.pump(tester);

      final gesture = await dragDown(tester, 120);

      expect(harness.state(tester).backgroundOpacity, 127 / 255);
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 300));
    });

    testWidgets('a drag past a sixth of the height closes onto the origin', (
      tester,
    ) async {
      final harness = ViewerHarness();
      await harness.pump(tester);

      final gesture = await dragDown(tester, 140);
      await gesture.up();
      await tester.pump();
      expect(harness.morphRect(tester).top, fittedRect.top + 140);

      await tester.pump(const Duration(milliseconds: 201));

      expect(harness.closed, 1);
      expect(harness.bridge.hidden, isEmpty);
    });

    testWidgets('an upward drag never dismisses', (tester) async {
      final harness = ViewerHarness();
      await harness.pump(tester);

      final gesture = await tester.startGesture(const Offset(200, 600));
      await gesture.moveBy(const Offset(0, -300));
      await tester.pump();
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 300));

      expect(harness.state(tester).dragOffset, 0);
      expect(harness.closed, 0);
    });

    testWidgets('without an origin the picture slides off the way it went', (
      tester,
    ) async {
      final harness = ViewerHarness();
      await harness.pump(tester);
      harness.bridge.origins.clear();

      final gesture = await dragDown(tester, 200);
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(harness.morphRect(tester).top, greaterThan(fittedRect.top + 200));
      await tester.pump(const Duration(milliseconds: 101));
      expect(harness.closed, 1);
    });

    testWidgets('closing on another item reveals its origin first', (
      tester,
    ) async {
      final harness = ViewerHarness();
      harness.bridge.origins[1] = const GalleryOrigin(rect: originRect);
      await harness.pump(tester);

      await tester.fling(
        find.byType(ViewerPhotoPage),
        const Offset(-300, 0),
        1000,
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(harness.state(tester).index, 1);

      final closing = harness.state(tester).close();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 201));
      await closing;

      expect(harness.bridge.revealed, [1]);
      expect(harness.bridge.hideCalls, [
        (0, true),
        (0, false),
        (1, true),
        (1, false),
      ]);
      expect(harness.closed, 1);
    });
  });

  group('zoom', () {
    Future<void> doubleTap(WidgetTester tester, Offset at) async {
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(at);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 251));
    }

    testWidgets('double tap zooms 3x around the tap, again back to 1x', (
      tester,
    ) async {
      final harness = ViewerHarness();
      await harness.pump(tester);

      await doubleTap(tester, const Offset(250, 400));
      expect(harness.page(tester).zoom, 3);
      // The point 50 px right of the centre stays under the finger.
      expect(harness.page(tester).pan, const Offset(-100, 0));

      await doubleTap(tester, const Offset(250, 400));
      expect(harness.page(tester).zoom, 1);
      expect(harness.page(tester).pan, Offset.zero);
    });

    testWidgets('a pinch past 3x settles at 3x', (tester) async {
      final harness = ViewerHarness();
      await harness.pump(tester);

      final a = await tester.startGesture(const Offset(180, 400));
      final b = await tester.startGesture(const Offset(220, 400));
      // The first step wins the arena; the scale counts from there.
      await a.moveTo(const Offset(140, 400));
      await tester.pump();
      await a.moveTo(const Offset(20, 400));
      await b.moveTo(const Offset(380, 400));
      await tester.pump();
      expect(harness.page(tester).zoom, greaterThan(3));

      await a.up();
      await b.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 251));

      expect(harness.page(tester).zoom, 3);
    });

    testWidgets('a pinch below 1x settles back at 1x', (tester) async {
      final harness = ViewerHarness();
      await harness.pump(tester);

      final a = await tester.startGesture(const Offset(100, 400));
      final b = await tester.startGesture(const Offset(300, 400));
      await a.moveTo(const Offset(140, 400));
      await tester.pump();
      await a.moveTo(const Offset(180, 400));
      await b.moveTo(const Offset(220, 400));
      await tester.pump();
      expect(harness.page(tester).zoom, lessThan(1));

      await a.up();
      await b.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 251));

      expect(harness.page(tester).zoom, 1);
    });

    testWidgets('a zoomed picture does not page', (tester) async {
      final harness = ViewerHarness();
      await harness.pump(tester);
      await doubleTap(tester, const Offset(200, 400));

      await tester.fling(
        find.byType(ViewerPhotoPage),
        const Offset(-300, 0),
        1000,
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(harness.state(tester).index, 0);
    });
  });
}
