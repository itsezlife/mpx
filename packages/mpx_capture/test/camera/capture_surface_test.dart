import 'dart:io';

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
  final refusals = <CaptureVideoRefusal>[];
  setUp(refusals.clear);
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
    bool videoNeedsMicrophone = true,
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
          onVideoRefused: refusals.add,
          videoNeedsMicrophone: videoNeedsMicrophone,
        ),
      ),
    );
    return session;
  }

  Finder shutter() => find.byKey(const ValueKey('mpx-capture-shutter'));

  Future<void> settle(WidgetTester tester) async {
    // Captures write real files (and the cache reads them): let real time
    // pass, then build what changed.
    // Captures write and read real files: let real time pass.
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
  }

  testWidgets('the page keeps the session ready to record while it shows '
      '(not for photos only), and lets it go when it closes', (tester) async {
    final session = await pumpSurface(tester) as FakeCameraSession;
    await settle(tester);
    expect(session.videoPrepared, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(session.videoPrepared, isFalse);
    final photos =
        await pumpSurface(tester, kinds: CaptureKinds.photo)
            as FakeCameraSession;
    await settle(tester);
    expect(photos.videoPrepared, isFalse);
  });

  testWidgets('shows the preview texture and lifts the cap', (tester) async {
    final session = await pumpSurface(tester);
    expect(find.byType(Texture), findsOneWidget);
    expect(session.value.value.frameRateCap, isNull);
  });

  group('the camera at hand', () {
    setUp(() {});

    testWidgets('a tap on the picture focuses there and rings it: the ring '
        'closes in over 200 ms, then fades', (tester) async {
      tester.view
        ..physicalSize = const Size(400, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final session = await pumpSurface(tester);
      await tester.tapAt(const Offset(100, 400));
      await tester.pump();
      expect((session as FakeCameraSession).focusedAt, [
        const Offset(0.25, 0.5),
      ]);
      final ring = find.byKey(const ValueKey('mpx-capture-focus'));
      expect(ring, findsOneWidget);
      expect(tester.getCenter(ring), const Offset(100, 400));
      await tester.pump(const Duration(milliseconds: 520));
      expect(ring, findsNothing);
    });

    testWidgets('two fingers spreading zoom in by their spread over 100, '
        'past a first stretch of slop', (tester) async {
      tester.view
        ..physicalSize = const Size(400, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final session = await pumpSurface(tester);
      final a = await tester.startGesture(const Offset(150, 400));
      final b = await tester.startGesture(const Offset(250, 400));
      await a.moveBy(const Offset(-10, 0));
      await b.moveBy(const Offset(10, 0));
      await tester.pump();
      expect(session.value.value.zoom, 0, reason: 'inside the slop');
      await a.moveBy(const Offset(-30, 0));
      await b.moveBy(const Offset(30, 0));
      await tester.pump();
      await a.moveBy(const Offset(-20, 0));
      await b.moveBy(const Offset(20, 0));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      // The slop ends at 150 px apart; from there to 220: 0.7.
      expect(session.value.value.zoom, closeTo(0.7, 1e-9));
      await a.up();
      await b.up();
    });

    testWidgets('while recording, a timer counts the seconds in a pill at '
        'the top', (tester) async {
      await pumpSurface(tester);
      final hold = await tester.startGesture(tester.getCenter(shutter()));
      await tester.pump(
        CameraCaptureSurface.holdToRecord + const Duration(milliseconds: 50),
      );
      await settle(tester);
      final timer = find.byKey(const ValueKey('mpx-capture-timer'));
      expect(timer, findsOneWidget);
      expect(
        find.descendant(of: timer, matching: find.text('0:00')),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 1));
      expect(
        find.descendant(of: timer, matching: find.text('0:01')),
        findsOneWidget,
      );
      final style = tester
          .widget<Text>(find.descendant(of: timer, matching: find.byType(Text)))
          .style!;
      expect(style.fontSize, 15);
      expect(style.fontWeight, FontWeight.bold);
      await hold.up();
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(timer, findsNothing);
    });
  });

  group('the zoom slider', () {
    Finder slider() => find.byKey(const ValueKey('mpx-capture-zoom'));
    double shown(WidgetTester tester) => tester
        .widget<Opacity>(
          find.ancestor(of: slider(), matching: find.byType(Opacity)).first,
        )
        .opacity;

    // A short pinch shows the slider.
    Future<void> reveal(WidgetTester tester) async {
      final a = await tester.startGesture(const Offset(150, 300));
      final b = await tester.startGesture(const Offset(250, 300));
      await a.moveBy(const Offset(-40, 0));
      await b.moveBy(const Offset(40, 0));
      await a.moveBy(const Offset(-5, 0));
      await b.moveBy(const Offset(5, 0));
      await a.up();
      await b.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }

    Future<CameraSession> pumpWide(WidgetTester tester) async {
      tester.view
        ..physicalSize = const Size(400, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      return pumpSurface(tester);
    }

    testWidgets('it lies 50 high, 126 above the bottom, hidden until the zoom '
        'is used; it shows over 180 ms and hides 2 s after the last use', (
      tester,
    ) async {
      final session = await pumpWide(tester);
      expect(tester.getRect(slider()), const Rect.fromLTWH(0, 624, 400, 50));
      expect(shown(tester), 0);
      final a = await tester.startGesture(const Offset(150, 300));
      final b = await tester.startGesture(const Offset(250, 300));
      await a.moveBy(const Offset(-40, 0));
      await b.moveBy(const Offset(40, 0));
      await a.moveBy(const Offset(-10, 0));
      await b.moveBy(const Offset(10, 0));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(session.value.value.zoom, greaterThan(0));
      await tester.pump(const Duration(milliseconds: 90));
      expect(shown(tester), inExclusiveRange(0, 1));
      await tester.pump(const Duration(milliseconds: 90));
      expect(shown(tester), 1);
      await a.up();
      await b.up();
      await tester.pump(const Duration(milliseconds: 1800));
      expect(shown(tester), 1);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 180));
      expect(shown(tester), 0);
    });

    testWidgets('its knob drags the zoom along the track; a tap on the track '
        'jumps there', (tester) async {
      final session = await pumpWide(tester);
      await reveal(tester);
      await tester.runAsync(() => session.setZoom(0));
      await tester.tapAt(const Offset(400 - 41, 649));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(session.value.value.zoom, closeTo(0.25, 1e-6));
      // The track runs from 59 to 341.
      const knob = 59 + 282 * 0.25;
      final drag = await tester.startGesture(const Offset(knob, 649));
      await drag.moveTo(const Offset(59 + 282 * 0.75, 649));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(session.value.value.zoom, closeTo(0.75, 1e-6));
      await drag.up();
      await tester.tapAt(const Offset(59 + 282 * 0.4, 649));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(session.value.value.zoom, closeTo(0.4, 1e-6));
    });

    testWidgets('the knob is the reference image\'s 12 disc, 16.7 pressed', (
      tester,
    ) async {
      final session = await pumpWide(tester);
      await reveal(tester);
      final paint = find.descendant(
        of: slider(),
        matching: find.byType(CustomPaint),
      );
      expect(tester.renderObject(paint), paints..circle(radius: 6));
      final knob =
          tester.getTopLeft(slider()) +
          Offset(59 + 282 * session.value.value.zoom, 25);
      final press = await tester.startGesture(knob);
      await tester.pump();
      expect(tester.renderObject(paint), paints..circle(radius: 50 / 60 * 10));
      await press.up();
    });

    testWidgets('minus and plus step to the quarter below and above over '
        '180 ms', (tester) async {
      final session = await pumpWide(tester);
      await reveal(tester);
      await tester.runAsync(() => session.setZoom(0.6));
      await tester.tapAt(const Offset(41, 649));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(session.value.value.zoom, inExclusiveRange(0.25, 0.6));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      // floor(0.6 / 0.25) * 0.25 - 0.25
      expect(session.value.value.zoom, closeTo(0.25, 1e-6));
      await tester.tapAt(const Offset(400 - 41, 649));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(session.value.value.zoom, closeTo(0.5, 1e-6));
    });

    testWidgets('a held shutter dragged above its top zooms by the distance '
        'over 200, and back to the widest when it comes down', (tester) async {
      final session = await pumpWide(tester);
      final top = tester.getRect(shutter()).top;
      final hold = await tester.startGesture(tester.getCenter(shutter()));
      await tester.pump(
        CameraCaptureSurface.holdToRecord + const Duration(milliseconds: 50),
      );
      await settle(tester);
      await hold.moveTo(Offset(tester.getCenter(shutter()).dx, top - 100));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(session.value.value.zoom, closeTo(0.5, 1e-6));
      await tester.pump(const Duration(milliseconds: 200));
      expect(shown(tester), 1);
      await hold.moveTo(tester.getCenter(shutter()));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(session.value.value.zoom, 0);
      await hold.up();
      await settle(tester);
      expect(shots.single.isVideo, isTrue);
    });
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

  testWidgets('a front camera photo is mirrored as the preview shows it, a '
      'back one is not', (tester) async {
    final session = await pumpSurface(tester);
    await tester.tap(shutter());
    await settle(tester);
    await tester.runAsync(session.switchCamera);
    (session as FakeCameraSession).deliverSwitchFrames();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(shutter());
    await settle(tester);
    expect(session.photosMirrored, [false, true]);
  });

  testWidgets('a recording slides the flash and the switch out to their '
      'edge, fading, over 150 ms; they come back after', (tester) async {
    await pumpSurface(tester);
    Finder slot(String name) => find.byKey(ValueKey('mpx-capture-$name-slot'));
    double opacity(String name) => tester
        .widget<Opacity>(
          find.descendant(of: slot(name), matching: find.byType(Opacity)).first,
        )
        .opacity;
    double shift(String name) => tester
        .widget<Transform>(
          find
              .descendant(of: slot(name), matching: find.byType(Transform))
              .first,
        )
        .transform
        .getTranslation()
        .x;
    expect(opacity('flash'), 1);
    expect(opacity('switch'), 1);
    final hold = await tester.startGesture(tester.getCenter(shutter()));
    await tester.pump(
      CameraCaptureSurface.holdToRecord + const Duration(milliseconds: 50),
    );
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 75));
    expect(opacity('flash'), inExclusiveRange(0, 1));
    expect(shift('switch'), inExclusiveRange(0, 30));
    await tester.pump(const Duration(milliseconds: 80));
    for (final name in ['flash', 'switch']) {
      expect(opacity(name), 0, reason: name);
      expect(shift(name), 30, reason: name);
    }
    await hold.up();
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 160));
    for (final name in ['flash', 'switch']) {
      expect(opacity(name), 1, reason: name);
      expect(shift(name), 0, reason: name);
    }
  });

  testWidgets('the zoom goes back to the widest after each shot', (
    tester,
  ) async {
    final session = await pumpSurface(tester);
    await tester.runAsync(() => session.setZoom(0.6));
    await tester.tap(shutter());
    await settle(tester);
    expect(shots, hasLength(1));
    expect(session.value.value.zoom, 0);
  });

  testWidgets('a hold records only after 800 ms; the pressed shutter grows '
      'to 1.06 over 120 ms and settles 40 ms after the release', (
    tester,
  ) async {
    final session = await pumpSurface(tester);
    double scale() => tester
        .widget<Transform>(
          find.descendant(of: shutter(), matching: find.byType(Transform)),
        )
        .transform
        .getMaxScaleOnAxis();
    expect(
      CameraCaptureSurface.holdToRecord,
      const Duration(milliseconds: 800),
    );
    final press = await tester.startGesture(tester.getCenter(shutter()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(scale(), inExclusiveRange(1, 1.06));
    await tester.pump(const Duration(milliseconds: 60));
    expect(scale(), closeTo(1.06, 1e-9));
    await tester.pump(const Duration(milliseconds: 600));
    await settle(tester);
    expect(session.value.value.isRecording, isFalse, reason: 'at 720 ms');
    await tester.pump(const Duration(milliseconds: 100));
    await settle(tester);
    expect(session.value.value.isRecording, isTrue);
    await press.up();
    await tester.pump(const Duration(milliseconds: 39));
    expect(scale(), closeTo(1.06, 1e-9));
    await tester.pump(const Duration(milliseconds: 2));
    await tester.pump(const Duration(milliseconds: 120));
    expect(scale(), closeTo(1, 1e-9));
    await settle(tester);
  });

  group('video refused', () {
    Future<void> hold(WidgetTester tester) async {
      final press = await tester.startGesture(tester.getCenter(shutter()));
      await tester.pump(
        CameraCaptureSurface.holdToRecord + const Duration(milliseconds: 50),
      );
      await settle(tester);
      await press.up();
      await settle(tester);
    }

    testWidgets('a hold where only photos are allowed is refused, and '
        'records nothing', (tester) async {
      final session = await pumpSurface(tester, kinds: CaptureKinds.photo);
      await hold(tester);
      expect(refusals, [CaptureVideoRefusal.notAllowed]);
      expect(shots, isEmpty);
      expect(session.value.value.isRecording, isFalse);
    });

    testWidgets('without the microphone a hold asks for it and records '
        'nothing; granted, the next hold records', (tester) async {
      sessions
        ..microphone = MicrophoneAccess.notDetermined
        ..microphoneOnRequest = MicrophoneAccess.granted;
      final session = await pumpSurface(tester);
      await hold(tester);
      expect(sessions.microphoneRequests, 1);
      expect(refusals, isEmpty);
      expect(shots, isEmpty);
      expect(session.value.value.microphone, MicrophoneAccess.granted);
      await hold(tester);
      expect(shots.single.isVideo, isTrue);
    });

    testWidgets('a refused microphone tells the host', (tester) async {
      sessions
        ..microphone = MicrophoneAccess.notDetermined
        ..microphoneOnRequest = MicrophoneAccess.denied;
      await pumpSurface(tester);
      await hold(tester);
      expect(refusals, [CaptureVideoRefusal.microphone]);
      expect(shots, isEmpty);
    });

    testWidgets('a surface that records without sound does not ask', (
      tester,
    ) async {
      sessions.microphone = MicrophoneAccess.denied;
      await pumpSurface(tester, videoNeedsMicrophone: false);
      await hold(tester);
      expect(sessions.microphoneRequests, 0);
      expect(shots.single.isVideo, isTrue);
    });
  });

  testWidgets('a hold records a video until released', (tester) async {
    final session = await pumpSurface(tester);
    final gesture = await tester.startGesture(tester.getCenter(shutter()));
    await tester.pump(
      CameraCaptureSurface.holdToRecord + const Duration(milliseconds: 50),
    );
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
    await tester.pump(
      CameraCaptureSurface.holdToRecord + const Duration(milliseconds: 50),
    );
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

  testWidgets('the kept shots: a strip of 80 tiles at the bottom, a '
      'counter in the host\'s words that opens them, the shutter 96 up', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(400, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final kept = ValueNotifier(<CameraShot>[]);
    addTearDown(kept.dispose);
    var opened = 0;
    final session = await tester.runAsync(() => sessions.open());
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: CameraCaptureSurface(
          session: session!,
          labels: CaptureSurfaceLabels(
            close: 'Close',
            shutter: 'Shutter',
            switchCamera: 'Switch camera',
            flash: 'Flash',
            shotsCount: (photos, videos) => '$photos/$videos',
          ),
          outputDirectory: directory.path,
          onCaptured: shots.add,
          onClose: () {},
          shots: kept,
          onShotsTap: () => opened++,
        ),
      ),
    );
    final counter = find.byKey(const ValueKey('mpx-capture-counter'));
    expect(counter, findsNothing);
    final shutterAt = tester.getCenter(shutter()).dy;
    for (var i = 0; i < 2; i++) {
      await tester.tap(shutter());
      await settle(tester);
    }
    expect(counter, findsNothing, reason: 'the host keeps none yet');
    kept.value = [...shots];
    await tester.pump();
    expect(
      find.descendant(of: counter, matching: find.text('2/0')),
      findsOneWidget,
    );
    expect(tester.getSize(counter).height, 38);
    expect(tester.getRect(counter).bottom, 800 - 225);
    final strip = find.byKey(const ValueKey('mpx-capture-shots'));
    expect(tester.getRect(strip), const Rect.fromLTRB(0, 712, 400, 792));
    expect(tester.getCenter(shutter()).dy, shutterAt - 96);
    await tester.tap(counter);
    expect(opened, 1);
  });

  testWidgets('a kept shot\'s strip cell: 80 square 6 apart, the picture '
      '(a recording\'s first frame), its duration, the selection number; a '
      'tap toggles it', (tester) async {
    tester.view
      ..physicalSize = const Size(400, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final kept = ValueNotifier(<CameraShot>[]);
    addTearDown(kept.dispose);
    final selected = ValueNotifier(<CameraShot>[]);
    addTearDown(selected.dispose);
    final session = await tester.runAsync(() => sessions.open());
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: CameraCaptureSurface(
          session: session!,
          labels: CaptureSurfaceLabels(
            close: 'Close',
            shutter: 'Shutter',
            switchCamera: 'Switch camera',
            flash: 'Flash',
            shotsCount: (photos, videos) => '$photos/$videos',
          ),
          outputDirectory: directory.path,
          onCaptured: shots.add,
          onClose: () {},
          shots: kept,
          shotSelection: selected,
          shotOrder: (shot) {
            final i = selected.value.indexOf(shot);
            return i < 0 ? null : i + 1;
          },
          onShotToggle: (shot) {
            final now = [...selected.value];
            if (!now.remove(shot)) now.add(shot);
            selected.value = now;
          },
          videoNeedsMicrophone: false,
        ),
      ),
    );
    await tester.tap(shutter());
    // The photo's file is read for its cell before the next shot.
    for (var i = 0; i < 5 && shots.isEmpty; i++) {
      await settle(tester);
    }
    final hold = await tester.startGesture(tester.getCenter(shutter()));
    await tester.pump(
      CameraCaptureSurface.holdToRecord + const Duration(milliseconds: 50),
    );
    await settle(tester);
    await tester.pump(const Duration(seconds: 1));
    await hold.up();
    for (var i = 0; i < 5 && shots.length < 2; i++) {
      await settle(tester);
    }
    expect(shots.map((s) => s.isVideo), [false, true]);
    // The posters decode on their own.
    for (var i = 0; i < 5; i++) {
      await settle(tester);
    }
    kept.value = [...shots];
    selected.value = [shots.last];
    await tester.pump();
    Finder cellOf(CameraShot shot) => find.byKey(
      ValueKey(('mpx-capture-shot', shot.key ?? shot.output.path)),
    );
    final video = cellOf(shots.last);
    expect(tester.getSize(cellOf(shots.first)), const Size(86, 80));
    expect(tester.getSize(video), const Size(80, 80), reason: 'the last');
    expect(
      find.descendant(of: video, matching: find.byType(RawImage)),
      findsOneWidget,
      reason: "the recording's first frame",
    );
    final duration = find.descendant(
      of: video,
      matching: find.byKey(const ValueKey('mpx-capture-shot-duration')),
    );
    expect(tester.getSize(duration).height, 17);
    expect(
      tester.getBottomLeft(duration) - tester.getBottomLeft(video),
      const Offset(4, -4),
    );
    final check = find.descendant(
      of: video,
      matching: find.byKey(const ValueKey('mpx-capture-shot-check')),
    );
    expect(tester.getRect(check).size, const Size(24, 24));
    expect(
      tester.renderObject(check),
      paints..circle(color: const Color(0xFF229AF0)),
      reason: 'number 1',
    );
    await tester.tap(cellOf(shots.first));
    await tester.pump();
    expect(selected.value, [shots.last, shots.first]);
  });

  testWidgets('a camera page opened again shows the kept shots of an earlier '
      'one with their pictures', (tester) async {
    tester.view
      ..physicalSize = const Size(400, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final kept = ValueNotifier(<CameraShot>[]);
    addTearDown(kept.dispose);
    const labels = CaptureSurfaceLabels(
      close: 'Close',
      shutter: 'Shutter',
      switchCamera: 'Switch camera',
      flash: 'Flash',
      shotsCount: _count,
    );
    Future<void> page(CameraSession session, Key key) => tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: CameraCaptureSurface(
          key: key,
          session: session,
          labels: labels,
          outputDirectory: directory.path,
          onCaptured: shots.add,
          onClose: () {},
          shots: kept,
          videoNeedsMicrophone: false,
        ),
      ),
    );
    final session = await tester.runAsync(() => sessions.open());
    await page(session!, const ValueKey('first'));
    final hold = await tester.startGesture(tester.getCenter(shutter()));
    await tester.pump(
      CameraCaptureSurface.holdToRecord + const Duration(milliseconds: 50),
    );
    await settle(tester);
    await tester.pump(const Duration(seconds: 1));
    await hold.up();
    for (var i = 0; i < 5 && shots.isEmpty; i++) {
      await settle(tester);
    }
    expect(shots.single.isVideo, isTrue);
    // Kept, then the page closes and another opens.
    kept.value = [...shots];
    await tester.pumpWidget(const SizedBox());
    await page(session, const ValueKey('second'));
    for (var i = 0; i < 5; i++) {
      await settle(tester);
    }
    final cell = find.byKey(
      ValueKey((
        'mpx-capture-shot',
        shots.single.key ?? shots.single.output.path,
      )),
    );
    expect(
      find.descendant(of: cell, matching: find.byType(RawImage)),
      findsOneWidget,
      reason: 'the picture comes back with the page',
    );
  });

  group('swipe to dismiss', () {
    double panel(WidgetTester tester) => tester
        .widget<Opacity>(find.byKey(const ValueKey('mpx-capture-panel')))
        .opacity;
    double dragged(WidgetTester tester) => tester
        .widget<Transform>(find.byKey(const ValueKey('mpx-capture-drag')))
        .transform
        .getTranslation()
        .y;

    Future<void> wide(WidgetTester tester) async {
      tester.view
        ..physicalSize = const Size(400, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpSurface(tester);
    }

    testWidgets('a short drag moves the preview, fades the controls over '
        '220 ms, and both come back over 250 ms', (tester) async {
      await wide(tester);
      final drag = await tester.startGesture(const Offset(200, 300));
      // The slop (18 for the recognizer, then 25 of ours) moves nothing.
      await drag.moveBy(const Offset(0, 20));
      await drag.moveBy(const Offset(0, 25));
      await tester.pump();
      expect(dragged(tester), 0);
      await drag.moveBy(const Offset(0, 80));
      await tester.pump();
      expect(dragged(tester), 80);
      await tester.pump(const Duration(milliseconds: 220));
      expect(panel(tester), 0);
      await drag.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 125));
      expect(dragged(tester), inExclusiveRange(0, 80));
      await tester.pump(const Duration(milliseconds: 130));
      expect(dragged(tester), 0);
      expect(panel(tester), 1);
      expect(closes, 0);
    });

    testWidgets('released past a sixth of the height it closes', (
      tester,
    ) async {
      await wide(tester);
      final drag = await tester.startGesture(const Offset(200, 300));
      await drag.moveBy(const Offset(0, -20));
      await drag.moveBy(const Offset(0, -25));
      await drag.moveBy(const Offset(0, -140));
      await tester.pump();
      expect(dragged(tester), -140);
      await drag.up();
      await tester.pump();
      expect(closes, 1, reason: '140 > 800 / 6');
    });
  });

  group('spam', () {
    testWidgets('switch taps while a switch runs make one switch', (
      tester,
    ) async {
      final held = FakeCameraSessions(textureId: 7, holdsSwitchFrames: true);
      final session = await pumpSurface(tester, from: held);
      for (var i = 0; i < 5; i++) {
        await tester.tap(find.byKey(const ValueKey('mpx-capture-switch')));
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      }
      expect((session as FakeCameraSession).switches, 1);
      expect(session.value.value.facing, CameraFacing.front);
      held.current!.deliverSwitchFrames();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('mpx-capture-switch')));
      await settle(tester);
      expect(session.switches, 2, reason: 'after its frames, a switch goes');
    });

    testWidgets('shutter taps while a photo is taken make one photo, and '
        'the switch and close wait for it', (tester) async {
      final slow = FakeCameraSessions(
        textureId: 7,
        photoTakes: const Duration(milliseconds: 300),
      );
      await pumpSurface(tester, from: slow);
      for (var i = 0; i < 5; i++) {
        await tester.tap(shutter());
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.tap(find.byKey(const ValueKey('mpx-capture-switch')));
      await tester.tap(find.byKey(const ValueKey('mpx-capture-close')));
      await tester.pump(const Duration(milliseconds: 400));
      await settle(tester);
      expect(shots, hasLength(1));
      expect(closes, 0);
      expect(slow.current!.value.value.facing, CameraFacing.back);
    });

    testWidgets('a second show for the same session while one is open does '
        'nothing', (tester) async {
      final session = await tester.runAsync(sessions.open);
      late BuildContext host;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Navigator(
            onGenerateRoute: (_) => PageRouteBuilder<void>(
              pageBuilder: (context, _, _) {
                host = context;
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      );
      for (var i = 0; i < 3; i++) {
        CameraCaptureSurface.show(
          host,
          session: session!,
          labels: _labels,
          outputDirectory: directory.path,
          onCaptured: shots.add,
        ).ignore();
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(CameraCaptureSurface), findsOneWidget);
    });
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
      // Past the icon's 220 ms swap.
      await tester.pump(const Duration(milliseconds: 230));
    }
    expect(flashes, [CameraFlash.auto, CameraFlash.on, CameraFlash.off]);

    // Taps within the swap's 220 ms are ignored.
    for (var i = 0; i < 5; i++) {
      await tester.tap(find.byKey(const ValueKey('mpx-capture-flash')));
      await tester.pump(const Duration(milliseconds: 10));
    }
    await settle(tester);
    expect(session.value.value.flash, CameraFlash.auto, reason: 'one change');
    await tester.pump(const Duration(milliseconds: 230));

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

String _count(int photos, int videos) => '$photos/$videos';
