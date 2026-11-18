import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_ui/mpx_ui.dart';

import 'viewer_harness.dart';

const _android = ViewerPolicy.$Android;
const _ios = ViewerPolicy.$IOS;
const _picture = Offset(200, 400);

// The controls read the playhead every frame while a video plays: pump
// frames rather than settle.
Future<void> _frames(WidgetTester tester, Duration total) async {
  const step = Duration(milliseconds: 50);
  for (var t = Duration.zero; t < total; t += step) {
    await tester.pump(step);
  }
}

void main() {
  group('single tap', () {
    testWidgets('Android: the chrome toggles 300 ms after the lift', (
      tester,
    ) async {
      final harness = ViewerHarness();
      await harness.pump(tester);
      expect(harness.state(tester).controlsVisible, isTrue);

      await tester.tapAt(_picture);
      await tester.pump(const Duration(milliseconds: 290));
      expect(harness.state(tester).controlsVisible, isTrue);
      await tester.pump(const Duration(milliseconds: 20));
      expect(harness.state(tester).controlsVisible, isFalse);
    });

    testWidgets('iOS: it waits 160 ms', (tester) async {
      final harness = ViewerHarness();
      await harness.pump(tester, policy: _ios);

      await tester.tapAt(_picture);
      await tester.pump(const Duration(milliseconds: 150));
      expect(harness.state(tester).controlsVisible, isTrue);
      await tester.pump(const Duration(milliseconds: 20));
      expect(harness.state(tester).controlsVisible, isFalse);
    });

    testWidgets('where a double tap does nothing, a tap is at once', (
      tester,
    ) async {
      final harness = ViewerHarness();
      // iOS turns double tap off within 44 pt of the edges.
      await harness.pump(tester, policy: _ios);

      await tester.tapAt(const Offset(200, 20));
      await tester.pump();
      expect(harness.state(tester).controlsVisible, isFalse);
    });

    testWidgets('a press that moves past the slop is no tap', (tester) async {
      final harness = ViewerHarness();
      await harness.pump(tester);

      final gesture = await tester.startGesture(_picture);
      await gesture.moveBy(const Offset(5, 7));
      await tester.pump();
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 400));
      expect(harness.state(tester).controlsVisible, isTrue);
    });

    testWidgets('Android: a side tap pages at once, with no double-tap wait', (
      tester,
    ) async {
      final harness = ViewerHarness();
      await harness.pump(tester);

      await tester.tapAt(const Offset(390, 400));
      await tester.pump();
      expect(harness.state(tester).index, 1);
      expect(harness.state(tester).controlsVisible, isTrue);
    });
  });

  group('double tap', () {
    testWidgets('zooms at the second press, before its lift', (tester) async {
      final harness = ViewerHarness();
      await harness.pump(tester);

      await tester.tapAt(_picture);
      await tester.pump(const Duration(milliseconds: 100));
      final second = await tester.startGesture(_picture);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 251));
      expect(harness.page(tester).zoom, 3);
      await second.up();
      await tester.pump(const Duration(milliseconds: 400));
      // And it was no single tap.
      expect(harness.state(tester).controlsVisible, isTrue);
    });

    testWidgets('a second press 100 px away is a new tap', (tester) async {
      final harness = ViewerHarness();
      await harness.pump(tester);

      await tester.tapAt(const Offset(150, 300));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tapAt(const Offset(150, 420));
      await tester.pump(const Duration(milliseconds: 400));
      expect(harness.page(tester).zoom, 1);
      // The first tap was dropped; the second toggled the chrome.
      expect(harness.state(tester).controlsVisible, isFalse);
    });

    testWidgets('Android: a second press within 40 ms is no double tap', (
      tester,
    ) async {
      final harness = ViewerHarness();
      await harness.pump(tester);

      await tester.tapAt(_picture);
      await tester.pump(const Duration(milliseconds: 20));
      await tester.tapAt(_picture);
      await tester.pump(const Duration(milliseconds: 400));
      expect(harness.page(tester).zoom, 1);
    });

    testWidgets('iOS: a double tap on a video does not zoom', (tester) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(1),
        videoDuration: const Duration(seconds: 10),
      );
      await harness.pump(tester, policy: _ios);

      await tester.tapAt(const Offset(200, 300));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(const Offset(200, 300));
      await _frames(tester, const Duration(milliseconds: 400));
      expect(harness.page(tester).zoom, 1);
    });
  });

  group('held press', () {
    Future<ViewerHarness> openVideo(
      WidgetTester tester, {
      Duration duration = const Duration(minutes: 1),
      int count = 1,
    }) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(count),
        videoDuration: duration,
      );
      await harness.pump(tester);
      return harness;
    }

    testWidgets(
      'Android: 300 ms on the right two thirds of a video plays it at 2x',
      (tester) async {
        final harness = await openVideo(tester);

        final gesture = await tester.startGesture(const Offset(300, 300));
        await tester.pump(const Duration(milliseconds: 250));
        expect(harness.lease(tester).state.value.speed, 1);
        await tester.pump(const Duration(milliseconds: 60));
        expect(harness.lease(tester).state.value.speed, 2);
        await gesture.up();
        await tester.pump();
        expect(harness.lease(tester).state.value.speed, 1);
      },
    );

    testWidgets('Android: not on the left third, nor under 8 s', (
      tester,
    ) async {
      var harness = await openVideo(tester);
      var gesture = await tester.startGesture(const Offset(60, 300));
      await tester.pump(const Duration(milliseconds: 350));
      expect(harness.lease(tester).state.value.speed, 1);
      await gesture.up();
      await _frames(tester, const Duration(milliseconds: 500));

      harness = await openVideo(tester, duration: const Duration(seconds: 7));
      gesture = await tester.startGesture(const Offset(300, 300));
      await tester.pump(const Duration(milliseconds: 350));
      expect(harness.lease(tester).state.value.speed, 1);
      await gesture.up();
      await _frames(tester, const Duration(milliseconds: 500));
    });

    testWidgets('a hold takes every move: no page, no dismiss', (tester) async {
      final harness = await openVideo(tester, count: 2);

      final gesture = await tester.startGesture(const Offset(300, 300));
      await tester.pump(const Duration(milliseconds: 350));
      expect(harness.lease(tester).state.value.speed, 2);
      await gesture.moveBy(const Offset(-200, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(0, 200));
      await tester.pump();
      expect(harness.state(tester).dragOffset, 0);
      await gesture.up();
      await _frames(tester, const Duration(milliseconds: 500));
      expect(harness.state(tester).index, 0);
      expect(harness.lease(tester).state.value.speed, 1);
    });

    testWidgets('a press that moves before the delay is no hold', (
      tester,
    ) async {
      final harness = await openVideo(tester);

      final gesture = await tester.startGesture(const Offset(300, 300));
      await gesture.moveBy(const Offset(0, 12));
      await tester.pump(const Duration(milliseconds: 350));
      expect(harness.lease(tester).state.value.speed, 1);
      await gesture.up();
      await _frames(tester, const Duration(milliseconds: 500));
    });
  });

  group('video controls above the gestures', () {
    testWidgets('the seek bar drag never pages or dismisses', (tester) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(2),
        videoDuration: const Duration(minutes: 1),
      );
      await harness.pump(tester);
      final bar = tester.getRect(
        find.byKey(const ValueKey('mpx-viewer-seek-bar')),
      );

      final gesture = await tester.startGesture(bar.centerLeft);
      await gesture.moveBy(Offset(bar.width / 2, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(0, -200));
      await tester.pump();
      expect(harness.state(tester).dragOffset, 0);
      await gesture.up();
      await _frames(tester, const Duration(milliseconds: 500));
      expect(harness.state(tester).index, 0);
      expect(harness.lease(tester).position.inSeconds, closeTo(30, 2));
    });

    testWidgets('the play button takes its tap; the chrome stays', (
      tester,
    ) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(1),
        videoDuration: const Duration(minutes: 1),
      );
      await harness.pump(tester);
      expect(harness.lease(tester).state.value.playing, isTrue);

      await tester.tap(find.byKey(const ValueKey('mpx-viewer-play')));
      await _frames(tester, const Duration(milliseconds: 400));
      expect(harness.lease(tester).state.value.playing, isFalse);
      expect(harness.state(tester).controlsVisible, isTrue);
    });
  });

  group('policy values', () {
    test('tap timings per platform', () {
      expect(_android.taps.doubleTapDelay, const Duration(milliseconds: 300));
      expect(_android.taps.minDoubleTapGap, const Duration(milliseconds: 40));
      expect(_ios.taps.doubleTapDelay, const Duration(milliseconds: 160));
      expect(_android.video.hold!.minDuration, const Duration(seconds: 8));
      expect(_android.video.doubleTapZooms, isTrue);
      expect(_ios.video.doubleTapZooms, isFalse);
    });
  });
}
