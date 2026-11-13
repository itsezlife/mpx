import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_ui/mpx_ui.dart';
import 'package:mpx_ui/testing.dart';

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
      expect(_android.video.autoHide, const Duration(milliseconds: 3000));
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

  group('origin frames', () {
    testWidgets('are owned by the viewer and freed with the pages', (
      tester,
    ) async {
      final harness = ViewerHarness(count: 5);
      final controller = ViewerController();
      addTearDown(controller.dispose);
      for (var i = 0; i < 5; i++) {
        harness.bridge.frames[i] = _image();
      }
      addTearDown(() {
        for (final frame in harness.bridge.frames.values) {
          frame.dispose();
        }
      });
      await harness.pump(tester, controller: controller);
      for (final index in [1, 2, 3]) {
        controller.jumpTo(index);
        await tester.pump();
      }

      // Pages 0 and 1 are out of reach of page 3: their pictures are gone;
      // 2 and 3 keep theirs.
      final handed = harness.bridge.handedFrames;
      expect({for (final (index, _) in handed) index}, containsAll([0, 3]));
      for (final (index, frame) in handed) {
        expect(frame.debugDisposed, index < 2, reason: 'frame of $index');
      }

      await tester.pumpWidget(const SizedBox());
      for (final (index, frame) in handed) {
        expect(frame.debugDisposed, isTrue, reason: 'frame of $index');
      }
    });
  });

  group('the origin frame', () {
    // Whether a paint of the viewer draws [frame] or a clone of it.
    PaintPattern drawsFrame(ui.Image frame) =>
        paints..something((method, arguments) {
          if (method != #drawImageRect) return false;
          final image = arguments.first as ui.Image;
          return image.isCloneOf(frame);
        });

    testWidgets('stands in until the content shows, then is gone: content '
        'with transparency never shows it beneath', (tester) async {
      final harness = ViewerHarness();
      final frame = _image();
      addTearDown(frame.dispose);
      harness.bridge.frames[0] = frame;
      await harness.pump(tester);

      expect(find.byType(MediaViewer), drawsFrame(frame));

      harness.producer
          .attemptsFor(
            AssetRequest(
              photoKey(0),
              harness.producer.attempts.first.request.spec,
            ),
          )
          .single
          .advance(AssetStage.full);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(MediaViewer), isNot(drawsFrame(frame)));
    });
  });

  group('rebuilt', () {
    testWidgets('with a new source and bridge, moves to them', (tester) async {
      final harness = ViewerHarness();
      final first = _SpySource(harness.source);
      final second = _SpySource(
        FakeGallerySource([
          for (var i = 0; i < 5; i++)
            GalleryItem(photoKey(i), size: const Size(1200, 900)),
        ]),
      );
      addTearDown(second.inner.dispose);
      final bridge = FakeOriginBridge();
      tester.view.physicalSize = viewerSize;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      addTearDown(() {
        harness.scope.dispose();
        harness.clock.dispose();
        harness.source.dispose();
      });
      Future<void> pumpOn(GallerySource source, OriginBridge bridge) =>
          tester.pumpWidget(
            Directionality(
              textDirection: TextDirection.ltr,
              child: MediaViewer(
                source: source,
                initialIndex: 0,
                bridge: bridge,
                scope: harness.scope,
              ),
            ),
          );
      await pumpOn(first, harness.bridge);
      await tester.pump();
      expect(harness.bridge.hidden, {0});

      await pumpOn(second, bridge);

      expect(first.listeners, isEmpty);
      expect(second.listeners, hasLength(1));
      expect(second.inner.requests, [0]);
      expect(harness.bridge.hidden, isEmpty);
      expect(bridge.hidden, {0});

      await tester.pumpWidget(const SizedBox());
      expect(second.listeners, isEmpty);
      expect(bridge.hidden, isEmpty);
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

/// A source that records who listens to it.
final class _SpySource implements GallerySource {
  _SpySource(this.inner);

  final FakeGallerySource inner;
  final List<VoidCallback> listeners = [];

  @override
  int get count => inner.count;

  @override
  GalleryItem? itemAt(int index) => inner.itemAt(index);

  @override
  void loadAround(int index) => inner.loadAround(index);

  @override
  void addListener(VoidCallback listener) => listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => listeners.remove(listener);
}

ui.Image _image() {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawPaint(Paint());
  final picture = recorder.endRecording();
  final image = picture.toImageSync(4, 3);
  picture.dispose();
  return image;
}
