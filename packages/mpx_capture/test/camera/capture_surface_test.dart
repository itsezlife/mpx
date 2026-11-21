import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx_capture/mpx_capture.dart';
import 'package:mpx_capture/testing.dart';

const _labels = CaptureSurfaceLabels(
  close: 'Close',
  shutter: 'Shutter',
  switchCamera: 'Switch camera',
  flash: 'Flash',
);

void main() {
  late Directory directory;
  late FakeCameraSessions sessions;
  late List<CameraShot> shots;
  late int closes;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('mpx_surface');
    sessions = FakeCameraSessions(textureId: 7);
    shots = [];
    closes = 0;
  });
  tearDown(() => directory.deleteSync(recursive: true));

  Future<CameraSession> pumpSurface(
    WidgetTester tester, {
    CaptureKinds kinds = CaptureKinds.photoAndVideo,
    CaptureCache? cache,
    FakeCameraSessions? from,
  }) async {
    final session = await tester.runAsync(
      () => (from ?? sessions).open(frameRateCap: 30),
    );
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: CameraCaptureSurface(
          session: session!,
          labels: _labels,
          outputDirectory: directory.path,
          onCaptured: shots.add,
          onClose: () => closes++,
          kinds: kinds,
          cache: cache,
        ),
      ),
    );
    return session;
  }

  Finder shutter() => find.byKey(const ValueKey('mpx-capture-shutter'));

  Future<void> settle(WidgetTester tester) async {
    // Captures write real files (and the cache reads them): let real time
    // pass, then build what changed.
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
  }

  testWidgets('shows the preview texture and lifts the cap', (tester) async {
    final session = await pumpSurface(tester);
    expect(find.byType(Texture), findsOneWidget);
    expect(session.value.value.frameRateCap, isNull);
  });

  testWidgets('a tap takes a photo', (tester) async {
    await pumpSurface(tester);
    await tester.tap(shutter());
    await settle(tester);
    expect(shots, hasLength(1));
    expect(shots.single.isVideo, isFalse);
    expect(shots.single.key, isNull);
    expect(File(shots.single.output.path).existsSync(), isTrue);
  });

  testWidgets('a hold records a video until released', (tester) async {
    final session = await pumpSurface(tester);
    final gesture = await tester.startGesture(tester.getCenter(shutter()));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await settle(tester);
    expect(session.value.value.isRecording, isTrue);
    await gesture.up();
    await settle(tester);
    expect(session.value.value.isRecording, isFalse);
    expect(shots.single.isVideo, isTrue);
  });

  testWidgets('photo only: a hold records nothing', (tester) async {
    final session = await pumpSurface(tester, kinds: CaptureKinds.photo);
    final gesture = await tester.startGesture(tester.getCenter(shutter()));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await settle(tester);
    expect(session.value.value.isRecording, isFalse);
    await gesture.up();
    await settle(tester);
    expect(shots, isEmpty);
  });

  testWidgets('video only: a tap starts and a tap stops', (tester) async {
    final session = await pumpSurface(tester, kinds: CaptureKinds.video);
    await tester.tap(shutter());
    await settle(tester);
    expect(session.value.value.isRecording, isTrue);
    await tester.tap(shutter());
    await settle(tester);
    expect(session.value.value.isRecording, isFalse);
    expect(shots.single.isVideo, isTrue);
  });

  testWidgets('with a cache the shot lands under a local key', (tester) async {
    final store = MemoryBytesCache();
    await pumpSurface(tester, cache: CaptureCache(store: store));
    await tester.tap(shutter());
    await settle(tester);
    await settle(tester);
    final shot = shots.single;
    expect(shot.key, isNotNull);
    final bytes = await tester.runAsync(
      () => store.read(CaptureCache.cacheKeyOf(shot.key!)),
    );
    expect(bytes, isNotNull);
    expect(File(shot.output.path).existsSync(), isFalse);
  });

  testWidgets('switch, flash and close', (tester) async {
    final session = await pumpSurface(tester);
    expect(session.value.value.facing, CameraFacing.back);
    await tester.tap(find.byKey(const ValueKey('mpx-capture-switch')));
    await settle(tester);
    expect(session.value.value.facing, CameraFacing.front);

    final flashes = <CameraFlash>[];
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byKey(const ValueKey('mpx-capture-flash')));
      await settle(tester);
      flashes.add(session.value.value.flash);
    }
    expect(flashes, [CameraFlash.auto, CameraFlash.on, CameraFlash.off]);

    await tester.tap(find.byKey(const ValueKey('mpx-capture-close')));
    expect(closes, 1);
  });

  testWidgets('no flash and no switch where the camera has none', (
    tester,
  ) async {
    await pumpSurface(
      tester,
      from: FakeCameraSessions(cameras: 1, hasFlash: false, textureId: 1),
    );
    expect(find.byKey(const ValueKey('mpx-capture-flash')), findsNothing);
    expect(find.byKey(const ValueKey('mpx-capture-switch')), findsNothing);
  });

  testWidgets('the controls are labelled for screen readers', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpSurface(tester);
    expect(find.bySemanticsLabel('Shutter'), findsOneWidget);
    expect(find.bySemanticsLabel('Close'), findsOneWidget);
    expect(find.bySemanticsLabel('Switch camera'), findsOneWidget);
    expect(find.bySemanticsLabel('Flash'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('hand-off: the slot preview and the surface share one running '
      'session', (tester) async {
    final session = await tester.runAsync(
      () => sessions.open(frameRateCap: 30),
    );
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Navigator(
          key: navigator,
          onGenerateRoute: (_) => PageRouteBuilder<void>(
            pageBuilder: (context, _, _) => Center(
              child: GestureDetector(
                onTap: () => CameraCaptureSurface.show(
                  context,
                  session: session,
                  labels: _labels,
                  outputDirectory: directory.path,
                  onCaptured: shots.add,
                ),
                child: SizedBox(
                  width: 100,
                  height: 200,
                  child: CameraPreview(session: session!),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(Texture), findsOneWidget);

    await tester.tap(find.byType(CameraPreview));
    await tester.pumpAndSettle();
    await settle(tester);
    expect(find.byType(CameraCaptureSurface), findsOneWidget);
    expect(session!.value.value.frameRateCap, isNull, reason: 'cap lifted');

    await tester.tap(find.byKey(const ValueKey('mpx-capture-close')));
    await tester.pumpAndSettle();
    await settle(tester);
    expect(find.byType(CameraCaptureSurface), findsNothing);
    expect(sessions.openCount, 1, reason: 'never reopened');
    expect(session.value.value.state, CameraSessionState.available);
    expect(session.value.value.frameRateCap, 30, reason: 'cap restored');
    expect(find.byType(Texture), findsOneWidget);
  });

  testWidgets('expanding from the slot over 350 ms on an ease curve, the '
      'preview grows from the slot to the screen and the controls fade in '
      'with it; closing takes 220 ms back the same way', (tester) async {
    tester.view
      ..physicalSize = const Size(400, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = await tester.runAsync(
      () => sessions.open(frameRateCap: 30),
    );
    late BuildContext home;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Navigator(
          onGenerateRoute: (_) => PageRouteBuilder<void>(
            pageBuilder: (context, _, _) {
              home = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    const slot = Rect.fromLTWH(10, 300, 90, 90);
    const screen = Rect.fromLTWH(0, 0, 400, 800);
    final controls = find.byKey(const ValueKey('mpx-capture-controls'));
    final preview = find.byType(CameraPreview);
    double opacity() => tester
        .widget<Opacity>(
          find.byKey(const ValueKey('mpx-capture-controls-fade')),
        )
        .opacity;
    void expectRect(Rect actual, Rect expected, String at) {
      for (final (a, e) in [
        (actual.left, expected.left),
        (actual.top, expected.top),
        (actual.right, expected.right),
        (actual.bottom, expected.bottom),
      ]) {
        expect(a, closeTo(e, 0.5), reason: '$at: $actual vs $expected');
      }
    }

    CameraCaptureSurface.show(
      home,
      session: session!,
      labels: _labels,
      outputDirectory: directory.path,
      onCaptured: shots.add,
      from: slot,
    ).ignore();
    await tester.pump();
    var at = 0;
    for (final ms in [0, 70, 175, 280, 350]) {
      if (ms > at) await tester.pump(Duration(milliseconds: ms - at));
      at = ms;
      final p = Curves.ease.transform(ms / 350);
      expectRect(
        tester.getRect(preview),
        Rect.lerp(slot, screen, p)!,
        '$ms ms',
      );
      expect(opacity(), closeTo(p, 1e-6), reason: 'controls with it, $ms ms');
      expect(tester.getSize(controls), screen.size, reason: '$ms ms');
      expect(tester.takeException(), isNull);
    }
    await settle(tester);

    await tester.tap(find.byKey(const ValueKey('mpx-capture-close')));
    await tester.pump();
    for (final ms in [0, 110, 220]) {
      if (ms > 0) await tester.pump(const Duration(milliseconds: 110));
      final p = 1 - Curves.ease.transform(ms / 220);
      if (preview.evaluate().isEmpty) break;
      expectRect(
        tester.getRect(preview),
        Rect.lerp(slot, screen, p)!,
        'close $ms ms',
      );
      expect(opacity(), closeTo(p, 1e-6), reason: 'close $ms ms');
    }
    await tester.pumpAndSettle();
    expect(find.byType(CameraCaptureSurface), findsNothing);
  });
}
