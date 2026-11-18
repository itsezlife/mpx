import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mpx_example/main.dart' as app;
import 'package:mpx_ui/mpx_ui.dart';

/// The viewer's gestures on a device, through the example app: paging by
/// drag and by fling, double tap and pinch zoom, a zoomed pan handed on to
/// the next page at the picture's edge, the chrome toggled by a tap, and a
/// drag to dismiss. A screenshot at each key moment.
///
/// Run with the driver to keep the screenshots (`build/screenshots/`):
/// `flutter drive --driver=test_driver/integration_test.dart
/// --target=integration_test/viewer_gestures_test.dart -d DEVICE`.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // The app plays animations all the time, so nothing settles: frames are
  // pumped for a wall-clock span instead.
  Future<void> wait(WidgetTester tester, int milliseconds) async {
    final end = DateTime.now().add(Duration(milliseconds: milliseconds));
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 16));
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
  }

  Future<void> until(
    WidgetTester tester,
    bool Function() done, {
    int timeoutMs = 20000,
  }) async {
    final end = DateTime.now().add(Duration(milliseconds: timeoutMs));
    while (!done()) {
      if (DateTime.now().isAfter(end)) fail('timed out');
      await wait(tester, 100);
    }
  }

  var shot = 0;
  Future<void> screenshot(WidgetTester tester, String name) async {
    await tester.pump();
    shot++;
    await binding.takeScreenshot('${shot.toString().padLeft(2, '0')}-$name');
  }

  // A drag in steps, so the page follows the finger frame by frame.
  Future<TestGesture> drag(
    WidgetTester tester,
    Offset from,
    Offset by, {
    int steps = 20,
  }) async {
    final gesture = await tester.startGesture(from);
    for (var i = 0; i < steps; i++) {
      await gesture.moveBy(by / steps.toDouble());
      await tester.pump(const Duration(milliseconds: 16));
    }
    return gesture;
  }

  Future<void> doubleTap(WidgetTester tester, Offset at) async {
    await tester.tapAt(at);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    await tester.tapAt(at);
    await wait(tester, 500);
  }

  testWidgets('the viewer pages, zooms, hands off, toggles and dismisses', (
    tester,
  ) async {
    await app.main();
    await until(tester, () => find.byType(ViewerOrigin).evaluate().isNotEmpty);
    await wait(tester, 1500);
    if (Platform.isAndroid) await binding.convertFlutterSurfaceToImage();
    await screenshot(tester, 'home');

    // Open on the still.
    await tester.tap(find.byType(ViewerOrigin).first);
    await until(tester, () => find.byType(MediaViewer).evaluate().isNotEmpty);
    await wait(tester, 800);
    MediaViewerState viewer() =>
        tester.state<MediaViewerState>(find.byType(MediaViewer));
    final size = tester.getSize(find.byType(MediaViewer));
    final centre = size.center(Offset.zero);
    await screenshot(tester, 'open');
    expect(viewer().index, 0);

    // A slow drag past half a page goes on to the next.
    final paging = await drag(
      tester,
      centre + Offset(size.width * 0.3, 0),
      Offset(-size.width * 0.55, 0),
    );
    await screenshot(tester, 'drag-between-pages');
    await paging.up();
    await wait(tester, 700);
    await screenshot(tester, 'paged-by-drag');
    expect(viewer().index, 1);

    // A short fast flick goes back.
    await tester.flingFrom(centre, Offset(size.width * 0.2, 0), 1500);
    await wait(tester, 700);
    await screenshot(tester, 'paged-back-by-fling');
    expect(viewer().index, 0);

    // Double tap zooms in at the point, again back out.
    await doubleTap(tester, centre);
    await screenshot(tester, 'double-tap-zoomed');
    await doubleTap(tester, centre);
    await screenshot(tester, 'double-tap-back');

    // A pinch out zooms; released, it settles within the range.
    final a = await tester.startGesture(centre - const Offset(40, 0));
    final b = await tester.startGesture(centre + const Offset(40, 0));
    for (var i = 0; i < 20; i++) {
      await a.moveBy(const Offset(-5, 0));
      await b.moveBy(const Offset(5, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await screenshot(tester, 'pinching');
    await a.up();
    await b.up();
    await wait(tester, 600);
    await screenshot(tester, 'pinch-settled');

    // Zoomed, a pan to the picture's right edge and on hands the drag to
    // the pager: the next page comes in.
    final pan = await drag(
      tester,
      centre + Offset(size.width * 0.4, 0),
      Offset(-size.width * 2.2, 0),
      steps: 40,
    );
    await screenshot(tester, 'zoomed-edge-hand-off');
    await pan.up();
    await wait(tester, 700);
    await screenshot(tester, 'paged-from-zoomed-edge');
    expect(viewer().index, 1);

    // A tap shows or hides the chrome, after the double-tap wait.
    final shown = viewer().controlsVisible;
    await tester.tapAt(centre);
    await wait(tester, 600);
    await screenshot(tester, 'chrome-toggled');
    expect(viewer().controlsVisible, !shown);
    await tester.tapAt(centre);
    await wait(tester, 600);
    await screenshot(tester, 'chrome-toggled-back');
    expect(viewer().controlsVisible, shown);

    // A drag down follows the finger, the background fading; released past
    // the policy's fraction the viewer closes.
    final dismiss = await drag(tester, centre, Offset(0, size.height * 0.35));
    await screenshot(tester, 'dismiss-dragging');
    await dismiss.up();
    await wait(tester, 1000);
    await screenshot(tester, 'dismissed');
    expect(find.byType(MediaViewer), findsNothing);
  });
}
