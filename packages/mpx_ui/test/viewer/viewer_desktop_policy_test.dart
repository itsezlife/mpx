import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_ui/mpx_ui.dart';

import 'viewer_harness.dart';

const _desktop = ViewerPolicy.$Desktop;

// The picture rests at (0, 250) to (400, 550); above and below is
// background.
const _background = Offset(200, 120);
const _picture = Offset(300, 300);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

Future<void> _command(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await _settle(tester);
}

void main() {
  group('values', () {
    test('zoom steps are multiples of the picture pixels, fit between', () {
      const fitted = Size(400, 300);
      const viewport = Size(400, 800);
      const pixels = Size(1200, 900);
      double? step(double zoom, {required bool zoomIn}) => _desktop.stepZoom(
        zoom,
        fitted,
        viewport,
        zoomIn: zoomIn,
        pixels: pixels,
      );

      // One picture pixel is 3 fitted units: 1:1 is 3x, 2:1 is 6x.
      expect(step(1, zoomIn: true), 3);
      expect(step(3, zoomIn: true), 6);
      expect(step(6, zoomIn: false), 3);
      expect(step(3, zoomIn: false), 1);
      expect(step(1, zoomIn: false), isNull);
      expect(step(24, zoomIn: true), isNull);
      expect(_desktop.maxZoomFor(fitted, viewport, pixels: pixels), 24);
    });

    test('no drag dismiss, background click closes, silent video loops', () {
      expect(_desktop.startsDismiss(0, 200), isFalse);
      expect(_desktop.backgroundClickCloses, isTrue);
      final video = _desktop.video;
      expect(video.loops(const Duration(minutes: 5), hasAudio: false), isTrue);
      expect(video.loops(const Duration(seconds: 5), hasAudio: true), isFalse);
      expect(video.autoHide, const Duration(milliseconds: 1100));
      expect(_desktop.controlsHideDuration, const Duration(milliseconds: 600));
      expect(video.speed.memory, ViewerSpeedMemory.global);
      expect(video.seekPreviewBox, isNull);
    });
  });

  group('photos', () {
    late ViewerHarness harness;

    Future<void> open(WidgetTester tester) async {
      harness = ViewerHarness();
      await harness.pump(tester, policy: _desktop);
    }

    testWidgets('the overlay is there at once', (tester) async {
      harness = ViewerHarness();
      await harness.pump(tester, policy: _desktop, open: false);
      await tester.pump();
      expect(harness.state(tester).isOpen, isTrue);
      expect(harness.state(tester).backgroundOpacity, 1);
    });

    testWidgets('a click on the background closes', (tester) async {
      await open(tester);

      await tester.tapAt(_background);
      await _settle(tester);
      expect(harness.closed, 1);
    });

    testWidgets('a click on the picture closes too, but not a drag', (
      tester,
    ) async {
      await open(tester);

      final drag = await tester.startGesture(_picture);
      await drag.moveBy(const Offset(15, 0));
      await tester.pump();
      await drag.up();
      await _settle(tester);
      expect(harness.closed, 0);

      await tester.tapAt(_picture);
      await _settle(tester);
      expect(harness.closed, 1);
    });

    testWidgets('a vertical drag does not dismiss', (tester) async {
      await open(tester);
      final gesture = await tester.startGesture(_picture);
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(const Offset(0, 30));
        await tester.pump();
      }
      await gesture.up();
      await _settle(tester);
      expect(harness.closed, 0);
      expect(harness.state(tester).dragOffset, 0);
    });

    testWidgets('Escape closes', (tester) async {
      await open(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(harness.closed, 1);
    });

    testWidgets('the arrows page', (tester) async {
      await open(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(harness.state(tester).index, 1);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(harness.state(tester).index, 0);
    });

    testWidgets('Ctrl with + - 0 zooms in steps', (tester) async {
      await open(tester);

      await _command(tester, LogicalKeyboardKey.equal);
      expect(harness.page(tester).zoom, 3);
      await _command(tester, LogicalKeyboardKey.equal);
      expect(harness.page(tester).zoom, 6);
      await _command(tester, LogicalKeyboardKey.minus);
      expect(harness.page(tester).zoom, 3);
      await _command(tester, LogicalKeyboardKey.digit0);
      expect(harness.page(tester).zoom, 1);
    });

    testWidgets('the wheel pages; with Ctrl it zooms', (tester) async {
      await open(tester);
      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(_picture));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 40)));
      await tester.pumpAndSettle();
      expect(harness.state(tester).index, 1);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, -40)));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await _settle(tester);
      expect(harness.page(tester).zoom, 3);
    });
  });

  group('video', () {
    late ViewerHarness harness;

    Future<void> open(WidgetTester tester, {bool hasAudio = true}) async {
      harness = ViewerHarness(
        items: ViewerHarness.videos(1, hasAudio: hasAudio),
        videoDuration: const Duration(seconds: 60),
      );
      await harness.pump(tester, policy: _desktop);
    }

    testWidgets('double click puts the window into fullscreen and back', (
      tester,
    ) async {
      await open(tester);
      await tester.tapAt(_picture);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(_picture);
      await _settle(tester);

      expect(harness.fullscreen, [true]);
      expect(harness.state(tester).fullscreen, isTrue);

      await _command(tester, LogicalKeyboardKey.keyF);
      expect(harness.fullscreen, [true, false]);
    });

    testWidgets('closing in fullscreen leaves it', (tester) async {
      await open(tester);
      await _command(tester, LogicalKeyboardKey.keyF);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(harness.fullscreen, [true, false]);
    });

    testWidgets('Space taps play or pause; held 200 ms it plays at 2x', (
      tester,
    ) async {
      await open(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      expect(harness.lease(tester).state.value.playing, isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      expect(harness.lease(tester).state.value.playing, isTrue);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.pump(const Duration(milliseconds: 250));
      expect(harness.lease(tester).state.value.speed, 2);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      expect(harness.lease(tester).state.value.speed, 1);
      expect(harness.lease(tester).state.value.playing, isTrue);
    });

    testWidgets('J and L seek 10 s; digits jump to tenths', (tester) async {
      await open(tester);
      harness.engine(0).advance(const Duration(seconds: 20));

      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      expect(harness.lease(tester).position, const Duration(seconds: 30));
      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      expect(harness.lease(tester).position, const Duration(seconds: 20));
      await tester.sendKeyEvent(LogicalKeyboardKey.digit5);
      expect(harness.lease(tester).position, const Duration(seconds: 30));
      await tester.pump();
    });

    testWidgets('in fullscreen the arrows seek 5 s', (tester) async {
      await open(tester);
      await _command(tester, LogicalKeyboardKey.keyF);
      harness.engine(0).advance(const Duration(seconds: 20));

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(harness.lease(tester).position, const Duration(seconds: 25));
      await tester.pump();
    });

    testWidgets('a silent video loops', (tester) async {
      await open(tester, hasAudio: false);
      expect(harness.lease(tester).state.value.looping, isTrue);
    });

    testWidgets('controls hide after 1.1 s; a mouse move shows them', (
      tester,
    ) async {
      await open(tester);
      await tester.pump(const Duration(milliseconds: 1200));
      expect(harness.state(tester).controlsVisible, isFalse);

      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(_picture));
      await tester.sendEventToBinding(
        mouse.hover(_picture + const Offset(10, 0)),
      );
      await tester.pump();
      expect(harness.state(tester).controlsVisible, isTrue);
    });
  });
}
