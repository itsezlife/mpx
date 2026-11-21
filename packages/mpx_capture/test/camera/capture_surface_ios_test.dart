import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_capture/mpx_capture.dart';
import 'package:mpx_capture/src/camera/capture_surface_parts.dart';
import 'package:mpx_capture/testing.dart';

const _labels = CaptureSurfaceLabels(
  close: 'Close',
  shutter: 'Shutter',
  switchCamera: 'Switch camera',
  flash: 'Flash',
  videoMode: 'VIDEO',
  photoMode: 'PHOTO',
);

void main() {
  late Directory directory;
  late FakeCameraSessions sessions;
  late List<CameraShot> shots;
  late List<CameraShot> removed;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('mpx_surface_ios');
    sessions = FakeCameraSessions(
      textureId: 7,
      minZoomFactor: 0.5,
      maxZoomFactor: 15,
      lenses: const [0.5, 1, 2],
    );
    shots = [];
    removed = [];
  });
  tearDown(() => directory.deleteSync(recursive: true));

  Future<CameraSession> pumpSurface(
    WidgetTester tester, {
    CaptureKinds kinds = CaptureKinds.photoAndVideo,
    CaptureSurfaceLabels labels = _labels,
  }) async {
    tester.view
      ..physicalSize = const Size(400, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = await tester.runAsync(
      () => sessions.open(frameRateCap: 30),
    );
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: CameraCaptureSurface(
          session: session!,
          labels: labels,
          outputDirectory: directory.path,
          onCaptured: shots.add,
          onClose: () {},
          kinds: kinds,
          policy: CaptureSurfacePolicy.$IOS,
          onShotRemoved: removed.add,
        ),
      ),
    );
    return session;
  }

  Finder shutter() => find.byKey(const ValueKey('mpx-capture-shutter'));

  Future<void> settle(WidgetTester tester) async {
    // Captures write and read real files: let real time pass.
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
  }

  Future<TestGesture> hold(WidgetTester tester) async {
    final press = await tester.startGesture(tester.getCenter(shutter()));
    await tester.pump(const Duration(milliseconds: 260));
    await settle(tester);
    return press;
  }

  double opacityOf(WidgetTester tester, String slot) => tester
      .widget<AnimatedOpacity>(
        find.descendant(
          of: find.byKey(ValueKey('mpx-capture-$slot-slot')),
          matching: find.byType(AnimatedOpacity),
        ),
      )
      .opacity;

  test('the platform picks the policy', () {
    expect(
      CaptureSurfacePolicy.forPlatform(TargetPlatform.iOS),
      same(CaptureSurfacePolicy.$IOS),
    );
    expect(
      CaptureSurfacePolicy.forPlatform(TargetPlatform.android),
      same(CaptureSurfacePolicy.$Android),
    );
    expect(
      CaptureSurfacePolicy.$IOS.holdToRecord,
      const Duration(milliseconds: 250),
    );
  });

  group('modes', () {
    testWidgets('photo mode first: a tap takes a photo; the video mode '
        'records on a tap and stops on the next', (tester) async {
      final session = await pumpSurface(tester);
      Text text(String key) => tester.widget<Text>(
        find.descendant(
          of: find.byKey(ValueKey('mpx-capture-mode-$key')),
          matching: find.byType(Text),
        ),
      );
      expect(text('photo').style!.color, captureAccent);
      expect(text('photo').style!.fontWeight, FontWeight.bold);
      expect(text('video').style!.fontWeight, FontWeight.normal);
      expect(text('photo').style!.letterSpacing, 0.75);
      await tester.tap(shutter());
      await settle(tester);
      expect(shots.single.isVideo, isFalse);
      await tester.tap(find.byKey(const ValueKey('mpx-capture-mode-video')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(text('video').style!.color, captureAccent);
      await tester.tap(shutter());
      await settle(tester);
      expect(session.value.value.isRecording, isTrue);
      await tester.tap(shutter());
      await settle(tester);
      expect(shots.last.isVideo, isTrue);
    });

    testWidgets('a 250 ms hold in photo mode moves to video and records '
        'until the release; the zoom is back to 1x 0.3 s after', (
      tester,
    ) async {
      final session = await pumpSurface(tester);
      await tester.runAsync(() => session.setZoomFactor(2));
      final press = await hold(tester);
      expect(session.value.value.isRecording, isTrue);
      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: find.byKey(const ValueKey('mpx-capture-mode-video')),
                matching: find.byType(Text),
              ),
            )
            .style!
            .color,
        captureAccent,
      );
      await press.up();
      await settle(tester);
      expect(shots.single.isVideo, isTrue);
      expect(session.value.value.zoomFactor, 2, reason: 'not after a shot');
      await tester.pump(const Duration(milliseconds: 310));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(session.value.value.zoomFactor, 1);
    });

    testWidgets('no mode control without the mode names, nor for one kind', (
      tester,
    ) async {
      await pumpSurface(tester, kinds: CaptureKinds.photo);
      expect(find.byKey(const ValueKey('mpx-capture-modes')), findsNothing);
    });

    testWidgets('a recording fades close, flash, switch and the modes out '
        'over 250 ms', (tester) async {
      await pumpSurface(tester);
      final press = await hold(tester);
      await tester.pump(const Duration(milliseconds: 250));
      for (final slot in ['close', 'flash', 'switch', 'modes']) {
        expect(opacityOf(tester, slot), 0, reason: slot);
      }
      await press.up();
      await settle(tester);
      for (final slot in ['close', 'flash', 'switch', 'modes']) {
        expect(opacityOf(tester, slot), 1, reason: slot);
      }
    });
  });

  group('zoom', () {
    testWidgets('a drag up from the recording shutter zooms 1 + d / 60, up '
        'to 8x; back down, 1x', (tester) async {
      final session = await pumpSurface(tester);
      final press = await hold(tester);
      await press.moveBy(const Offset(0, -120));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(session.value.value.zoomFactor, closeTo(3, 1e-9));
      await press.moveBy(const Offset(0, -600));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(session.value.value.zoomFactor, 8);
      await press.moveBy(const Offset(0, 800));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(session.value.value.zoomFactor, 1);
      await press.up();
      await settle(tester);
    });

    testWidgets('a pinch adds (scale - 1) x 1.25, twice that above 2x', (
      tester,
    ) async {
      final session = await pumpSurface(tester);
      final a = await tester.startGesture(const Offset(150, 300));
      final b = await tester.startGesture(const Offset(250, 300));
      // 100 apart to 120: scale 1.2.
      await b.moveBy(const Offset(20, 0));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(session.value.value.zoomFactor, closeTo(1.25, 1e-9));
      await a.up();
      await b.up();
      await tester.runAsync(() => session.setZoomFactor(3));
      final c = await tester.startGesture(const Offset(150, 300));
      final d = await tester.startGesture(const Offset(250, 300));
      await d.moveBy(const Offset(20, 0));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(session.value.value.zoomFactor, closeTo(3.5, 1e-9));
      await c.up();
      await d.up();
    });

    testWidgets('the lenses: a pill 43 high, 0.5 / 1x / 2, a tap moves the '
        'zoom there over 300 ms', (tester) async {
      final session = await pumpSurface(tester);
      final pill = find.byKey(const ValueKey('mpx-capture-lenses'));
      expect(tester.getSize(pill), const Size(3 * 43, 43));
      for (final label in ['0.5', '1×', '2']) {
        expect(
          find.descendant(of: pill, matching: find.text(label)),
          findsOneWidget,
          reason: label,
        );
      }
      await tester.tap(find.byKey(const ValueKey(('mpx-capture-lens', 2.0))));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(session.value.value.zoomFactor, inExclusiveRange(1, 2));
      await tester.pump(const Duration(milliseconds: 160));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(session.value.value.zoomFactor, closeTo(2, 1e-9));
      expect(
        find.descendant(of: pill, matching: find.text('2×')),
        findsOneWidget,
      );
    });

    testWidgets('a drag on the pill zooms by -dx / 60 and catches on a lens', (
      tester,
    ) async {
      final session = await pumpSurface(tester);
      final pill = find.byKey(const ValueKey('mpx-capture-lenses'));
      final drag = await tester.startGesture(tester.getCenter(pill));
      // Past the drag slop, then 30 left: +0.5 from 1x... caught at 1.5? No
      // lens there: 1.5.
      await drag.moveBy(const Offset(-20, 0));
      await drag.moveBy(const Offset(-30, 0));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      final at = session.value.value.zoomFactor;
      expect(at, greaterThan(1));
      // Moving on to near 2 catches there.
      await drag.moveBy(Offset(-(2 - at) * 60 + 1, 0));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(session.value.value.zoomFactor, 2);
      await drag.up();
    });

    testWidgets('lens labels: a whole factor without decimals, between '
        'lenses the factor in tenths', (tester) async {
      expect(lensLabel(0.5, selected: false), '0.5');
      expect(lensLabel(1, selected: true), '1×');
      expect(lensLabel(1.46, selected: true), '1.5×');
      expect(CaptureLensPill.selectedOf(const [0.5, 1, 2], 1.4), 1);
      expect(CaptureLensPill.selectedOf(const [0.5, 1, 2], 0.7), 0);
    });
  });

  group('the rest', () {
    testWidgets('flash goes off and auto only', (tester) async {
      final session = await pumpSurface(tester);
      final flash = find.byKey(const ValueKey('mpx-capture-flash'));
      final seen = <CameraFlash>[];
      for (var i = 0; i < 3; i++) {
        await tester.tap(flash);
        await settle(tester);
        seen.add(session.value.value.flash);
        await tester.pump(const Duration(milliseconds: 230));
      }
      expect(seen, [CameraFlash.auto, CameraFlash.off, CameraFlash.auto]);
    });

    testWidgets('the timer is MM:SS in a red box', (tester) async {
      await pumpSurface(tester);
      final press = await hold(tester);
      final timer = find.byKey(const ValueKey('mpx-capture-timer'));
      expect(
        find.descendant(of: timer, matching: find.text('00:00')),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 1));
      expect(
        find.descendant(of: timer, matching: find.text('00:01')),
        findsOneWidget,
      );
      final box = tester.widget<Container>(
        find.descendant(of: timer, matching: find.byType(Container)).first,
      );
      expect((box.decoration! as BoxDecoration).color, captureRed);
      expect(CaptureRedTimer.clock(3725), '01:02:05');
      await press.up();
      await settle(tester);
    });

    testWidgets('a focus tap puts the crosshair there and resets the '
        'exposure; a vertical drag sets it (up brighter), the crosshair '
        'dims to half after', (tester) async {
      final session = await pumpSurface(tester);
      await tester.runAsync(() => session.setExposure(0.3));
      await tester.tapAt(const Offset(200, 300));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(session.value.value.exposure, 0);
      final cross = find.byKey(const ValueKey('mpx-capture-crosshair'));
      expect(tester.getCenter(cross), const Offset(200, 300));
      CaptureCrosshairPainter painter() =>
          tester.widget<CustomPaint>(cross).painter! as CaptureCrosshairPainter;
      await tester.pump(const Duration(milliseconds: 150));
      expect(painter().appear, 1);
      expect(painter().opacity, 1);
      final drag = await tester.startGesture(const Offset(200, 400));
      await drag.moveBy(const Offset(0, -20));
      await drag.moveBy(const Offset(0, -375));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      // 375 up past the slop: half the range brighter.
      expect(session.value.value.exposure, closeTo(0.5, 1e-6));
      expect(painter().track, isTrue);
      await drag.up();
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 200));
      expect(painter().opacity, 0.5);
      expect(painter().track, isFalse);
    });

    testWidgets('the shutter is a 72 ring whose disc turns red in video '
        'mode and into a square while recording', (tester) async {
      await pumpSurface(tester);
      CaptureSquareShutterPainter painter() =>
          tester
                  .widget<CustomPaint>(
                    find.descendant(
                      of: shutter(),
                      matching: find.byType(CustomPaint),
                    ),
                  )
                  .painter!
              as CaptureSquareShutterPainter;
      expect(tester.getSize(shutter()), const Size(72, 72));
      expect(painter().video, 0);
      final press = await hold(tester);
      await tester.pump(const Duration(milliseconds: 250));
      expect(painter().video, 1);
      expect(painter().recording, 1);
      await press.up();
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 250));
      expect(painter().recording, 0);
      expect(painter().video, 1, reason: 'still in video mode');
    });

    testWidgets('a photo blinks the preview 50 ms after the tap: dark over '
        '70 ms, back over 150', (tester) async {
      await pumpSurface(tester);
      final blink = find.ancestor(
        of: find.byKey(const ValueKey('mpx-capture-blink')),
        matching: find.byType(FadeTransition),
      );
      double shade() => tester.widget<FadeTransition>(blink).opacity.value;
      await tester.tap(shutter());
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 70));
      expect(shade(), 1);
      // The fade back starts on the next frame.
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 75));
      expect(shade(), closeTo(0.5, 0.01));
      await tester.pump(const Duration(milliseconds: 75));
      expect(shade(), 0);
      await settle(tester);
    });

    testWidgets('the shots show in a strip; one removed goes to the host', (
      tester,
    ) async {
      await pumpSurface(tester);
      expect(find.byKey(const ValueKey('mpx-capture-results')), findsNothing);
      for (var i = 0; i < 2; i++) {
        await tester.tap(shutter());
        await settle(tester);
        await tester.pump(const Duration(milliseconds: 300));
      }
      final strip = find.byKey(const ValueKey('mpx-capture-results'));
      final removes = find.descendant(
        of: strip,
        matching: find.byKey(const ValueKey('mpx-capture-result-remove')),
      );
      expect(removes, findsNWidgets(2));
      await tester.tap(removes.first);
      await tester.pump();
      expect(removed.single, shots.first);
      expect(removes, findsOneWidget);
    });
  });
}
