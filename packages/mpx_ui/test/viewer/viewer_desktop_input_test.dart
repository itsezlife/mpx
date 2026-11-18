import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_ui/mpx_ui.dart';

import 'viewer_harness.dart';

const _desktop = ViewerPolicy.$Desktop;
const _picture = Offset(200, 400);

Future<ViewerHarness> _open(WidgetTester tester, {int count = 3}) async {
  final harness = ViewerHarness(count: count);
  await harness.pump(tester, policy: _desktop);
  return harness;
}

void main() {
  group('keys', () {
    testWidgets('the arrows switch at once, with no slide', (tester) async {
      final harness = await _open(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(harness.state(tester).index, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(harness.state(tester).index, 2);
    });

    testWidgets('Home and End do nothing, as on the reference', (tester) async {
      final harness = await _open(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pump();
      expect(harness.state(tester).index, 0);
    });
  });

  group('wheel and trackpad', () {
    testWidgets('each wheel notch is one item, down the next', (tester) async {
      final harness = await _open(tester);
      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(_picture));

      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 20)));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 20)));
      await tester.pump();
      expect(harness.state(tester).index, 2);
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, -20)));
      await tester.pump();
      expect(harness.state(tester).index, 1);
    });

    testWidgets('a vertical trackpad pan pages every 120 px', (tester) async {
      final harness = await _open(tester);
      final pad = TestPointer(2, PointerDeviceKind.trackpad);
      await tester.sendEventToBinding(pad.panZoomStart(_picture));
      await tester.sendEventToBinding(
        pad.panZoomUpdate(_picture, pan: const Offset(0, -119)),
      );
      await tester.pump();
      expect(harness.state(tester).index, 0);
      await tester.sendEventToBinding(
        pad.panZoomUpdate(_picture, pan: const Offset(0, -120)),
      );
      await tester.pump();
      expect(harness.state(tester).index, 1);
      await tester.sendEventToBinding(pad.panZoomEnd());
    });

    testWidgets(
      'a horizontal trackpad swipe goes to the neighbour once, the fingers '
      'to the right bringing the previous',
      (tester) async {
        final harness = ViewerHarness();
        final controller = ViewerController();
        addTearDown(controller.dispose);
        await harness.pump(tester, policy: _desktop, controller: controller);
        controller.jumpTo(1);
        await tester.pump();

        final pad = TestPointer(2, PointerDeviceKind.trackpad);
        await tester.sendEventToBinding(pad.panZoomStart(_picture));
        // Slowed to a fifth: 87 px is under the 17.5 px commit.
        await tester.sendEventToBinding(
          pad.panZoomUpdate(_picture, pan: const Offset(87, 0)),
        );
        await tester.pump();
        expect(harness.state(tester).index, 1);
        await tester.sendEventToBinding(
          pad.panZoomUpdate(_picture, pan: const Offset(400, 0)),
        );
        await tester.pump();
        expect(harness.state(tester).index, 0);
        await tester.sendEventToBinding(pad.panZoomEnd());
      },
    );

    testWidgets('a trackpad pinch zooms one step per quarter of scale', (
      tester,
    ) async {
      final harness = await _open(tester);
      final pad = TestPointer(2, PointerDeviceKind.trackpad);
      await tester.sendEventToBinding(pad.panZoomStart(_picture));
      await tester.sendEventToBinding(pad.panZoomUpdate(_picture, scale: 1.2));
      await tester.pump(const Duration(milliseconds: 250));
      expect(harness.page(tester).zoom, 1);
      await tester.sendEventToBinding(pad.panZoomUpdate(_picture, scale: 1.3));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(harness.page(tester).zoom, 3);
      await tester.sendEventToBinding(pad.panZoomEnd());
    });
  });

  group('mouse', () {
    testWidgets('a press on a side strip switches at once', (tester) async {
      final harness = await _open(tester);
      final mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        pointer: 7,
      );
      addTearDown(mouse.removePointer);

      await mouse.down(const Offset(380, 400));
      await tester.pump();
      expect(harness.state(tester).index, 1);
      await mouse.up();
      await tester.pump();
      expect(harness.closed, 0);
    });

    testWidgets('a strip with no item that way is not one', (tester) async {
      final harness = await _open(tester);

      await tester.tapAt(const Offset(20, 400), kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 300));
      expect(harness.state(tester).index, 0);
      expect(harness.closed, 1);
    });

    testWidgets('a mouse drag pans a zoomed picture and never pages', (
      tester,
    ) async {
      final harness = await _open(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.equal);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(harness.page(tester).zoom, 3);

      final mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        pointer: 7,
      );
      addTearDown(mouse.removePointer);
      await mouse.down(_picture);
      await mouse.moveBy(const Offset(-20, 0));
      await tester.pump();
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.move,
      );
      await mouse.moveBy(const Offset(-500, 0));
      await tester.pump();
      expect(harness.page(tester).pan.dx, -400);
      await mouse.up();
      await tester.pump(const Duration(milliseconds: 300));
      expect(harness.state(tester).index, 0);
      expect(harness.closed, 0);
    });

    testWidgets('the cursor is a hand over a strip that pages', (tester) async {
      await _open(tester);
      final mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        pointer: 7,
      );
      addTearDown(mouse.removePointer);
      Object? cursor() =>
          RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1);

      await mouse.addPointer(location: const Offset(380, 400));
      await tester.pump();
      expect(cursor(), SystemMouseCursors.click);
      // No item before the first: no hand on the left.
      await mouse.moveTo(const Offset(20, 400));
      await tester.pump();
      expect(cursor(), isNot(SystemMouseCursors.click));
    });

    testWidgets('a video click plays or pauses; the cursor hides with the '
        'controls', (tester) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(1),
        videoDuration: const Duration(minutes: 1),
      );
      await harness.pump(tester, policy: _desktop);
      final mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        pointer: 7,
      );
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: const Offset(200, 300));
      await tester.pump();
      expect(harness.lease(tester).state.value.playing, isTrue);

      await mouse.down(const Offset(200, 300));
      await mouse.up();
      // A double click toggles fullscreen: the click waits for it.
      await tester.pump(const Duration(milliseconds: 310));
      expect(harness.lease(tester).state.value.playing, isFalse);

      await mouse.down(const Offset(200, 300));
      await mouse.up();
      await tester.pump(const Duration(milliseconds: 310));
      expect(harness.lease(tester).state.value.playing, isTrue);
      // Playing, the controls hide after 1.1 s, and the cursor with them.
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(harness.state(tester).controlsVisible, isFalse);
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.none,
      );
    });
  });
}
