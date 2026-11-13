import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_ui/mpx_ui.dart';

import 'viewer_harness.dart';

const _ios = ViewerPolicy.$IOS;

Future<void> _doubleTap(WidgetTester tester, Offset at) async {
  await tester.tapAt(at);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tapAt(at);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

// The controls read the playhead every frame while a video plays.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  group('values', () {
    test('dismiss either way past a twelfth, or faster than 1 pt/ms', () {
      expect(_ios.startsDismiss(0, -3), isTrue);
      expect(_ios.dismisses(66, 800), isFalse);
      expect(_ios.dismisses(67, 800), isTrue);
      expect(_ios.dismisses(-67, 800), isTrue);
      expect(_ios.dismisses(20, 800, velocity: -1100), isTrue);
      expect(_ios.dismisses(20, 800, velocity: 900), isFalse);
    });

    test('the background is gone after 80 pt', () {
      expect(_ios.backgroundOpacityAt(40, 400), 0.5);
      expect(_ios.backgroundOpacityAt(80, 400), 0);
    });

    test('zoom reaches 3x, or the zoom that fills the screen', () {
      const viewport = Size(400, 800);
      expect(_ios.maxZoomFor(const Size(400, 300), viewport), 3);
      expect(_ios.maxZoomFor(const Size(400, 100), viewport), 8);
      expect(_ios.doubleTapZoomFor(const Size(400, 100), viewport), 8);
    });

    test('video: hidden controls, 4 s, 15 s seek split at 0.3, shared '
        'speed', () {
      final video = _ios.video;
      expect(video.controlsVisibleOnOpen, isFalse);
      expect(video.autoHide, const Duration(seconds: 4));
      final seek = video.doubleTapSeek!;
      const minute = Duration(minutes: 1);
      expect(
        seek.seekAt(110, 400, duration: minute, position: Duration.zero),
        const Duration(seconds: -15),
      );
      expect(
        seek.seekAt(130, 400, duration: minute, position: Duration.zero),
        const Duration(seconds: 15),
      );
      expect(video.speed.max, 2.5);
      expect(video.speed.memory, ViewerSpeedMemory.shared);
      expect(video.seekPreviewBox, const Size(160, 90));
    });

    test('the spring curve settles without overshoot', () {
      const curve = ViewerSpringCurve();
      expect(curve.transform(0), 0);
      expect(curve.transform(1), 1);
      var last = 0.0;
      for (var t = 0.05; t < 1; t += 0.05) {
        final value = curve.transform(t);
        expect(value, greaterThanOrEqualTo(last));
        expect(value, lessThanOrEqualTo(1));
        last = value;
      }
    });
  });

  group('photos', () {
    testWidgets('the picture is revealed from the origin crop; the '
        'background is in after 150 ms', (tester) async {
      final harness = ViewerHarness();
      await harness.pump(tester, policy: _ios, open: false);

      await tester.pump(const Duration(milliseconds: 150));
      final state = harness.state(tester);
      expect(state.backgroundOpacity, 1);
      expect(state.isOpen, isFalse);
      // The window the picture shows through is between the origin and the
      // resting place.
      final window = harness.morphRect(tester);
      expect(window.width, greaterThan(originRect.width));
      expect(window.width, lessThanOrEqualTo(fittedRect.width));

      await tester.pump(const Duration(milliseconds: 101));
      expect(state.isOpen, isTrue);
    });

    testWidgets('an upward drag past a twelfth closes', (tester) async {
      final harness = ViewerHarness();
      await harness.pump(tester, policy: _ios);

      final gesture = await tester.startGesture(const Offset(200, 400));
      // The first 36 px are the gesture's slop; 80 more pass a twelfth.
      for (var i = 0; i < 12; i++) {
        await gesture.moveBy(const Offset(0, -10));
        await tester.pump(const Duration(milliseconds: 100));
      }
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(harness.closed, 1);
    });

    testWidgets('a short fast flick closes', (tester) async {
      final harness = ViewerHarness();
      await harness.pump(tester, policy: _ios);

      await tester.flingFrom(const Offset(200, 400), const Offset(0, 40), 2000);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(harness.closed, 1);
    });

    testWidgets('double tap zooms all the way; not near the edges', (
      tester,
    ) async {
      final harness = ViewerHarness(
        items: [GalleryItem(photoKey(0), size: const Size(1200, 300))],
      );
      await harness.pump(tester, policy: _ios);

      await _doubleTap(tester, const Offset(200, 20));
      expect(harness.page(tester).zoom, 1);

      await _doubleTap(tester, const Offset(200, 400));
      expect(harness.page(tester).zoom, 8);
    });
  });

  group('video', () {
    late ViewerHarness harness;

    Future<void> open(WidgetTester tester) async {
      harness = ViewerHarness(
        items: ViewerHarness.videos(1),
        videoDuration: const Duration(seconds: 60),
      );
      await harness.pump(tester, policy: _ios);
      harness.engine(0).advance(const Duration(seconds: 20));
    }

    testWidgets('controls are hidden on open', (tester) async {
      await open(tester);
      expect(harness.state(tester).controlsVisible, isFalse);
    });

    testWidgets('double tap seeks 15 s, back left of 0.3 of the width', (
      tester,
    ) async {
      await open(tester);

      await _doubleTap(tester, const Offset(100, 300));
      expect(harness.lease(tester).position, const Duration(seconds: 5));

      await _doubleTap(tester, const Offset(150, 300));
      expect(harness.lease(tester).position, const Duration(seconds: 20));
    });

    testWidgets('a held press on the right plays 1x faster until release', (
      tester,
    ) async {
      await open(tester);

      final gesture = await tester.startGesture(const Offset(300, 300));
      await tester.pump(const Duration(milliseconds: 350));
      expect(harness.lease(tester).state.value.speed, 2);

      await gesture.up();
      await tester.pump();
      expect(harness.lease(tester).state.value.speed, 1);
    });

    testWidgets('a held press on the left does nothing', (tester) async {
      await open(tester);

      final gesture = await tester.startGesture(const Offset(60, 300));
      await tester.pump(const Duration(milliseconds: 350));
      expect(harness.lease(tester).state.value.speed, 1);
      await gesture.up();
      await _settle(tester);
    });

    testWidgets('controls hide 4 s after they show', (tester) async {
      await open(tester);
      await tester.tapAt(const Offset(200, 300));
      await tester.pump(const Duration(milliseconds: 400));
      expect(harness.state(tester).controlsVisible, isTrue);

      await tester.pump(const Duration(milliseconds: 3500));
      expect(harness.state(tester).controlsVisible, isTrue);
      await tester.pump(const Duration(milliseconds: 600));
      expect(harness.state(tester).controlsVisible, isFalse);
    });
  });
}
