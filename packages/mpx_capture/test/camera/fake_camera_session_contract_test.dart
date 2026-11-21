import 'dart:io';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_capture/mpx_capture.dart';
import 'package:mpx_capture/testing.dart';

void main() {
  late Directory directory;
  setUp(() => directory = Directory.systemTemp.createTempSync('mpx_camera'));
  tearDown(() => directory.deleteSync(recursive: true));

  for (final cameras in [2, 1]) {
    group('$cameras camera(s)', () {
      CameraSessionContract.run(
        () => CameraSessionHarness(
          sessions: FakeCameraSessions(cameras: cameras),
          outputDirectory: directory.path,
          recordFor: const Duration(milliseconds: 5),
        ),
      );
    });
  }

  test('without access the session opens denied and takes nothing', () async {
    final session = await FakeCameraSessions(allowed: false).open();
    expect(session.value.value.state, CameraSessionState.denied);
    await expectLater(
      session.capturePhoto(outputPath: '${directory.path}/x.jpg'),
      throwsA(isA<CaptureFailed>()),
    );
  });

  group('zoom', () {
    test('a 0..1 zoom moves the crop evenly between the factors', () {
      expect(CameraZoom.factorOf(0, 1, 10), 1);
      expect(CameraZoom.factorOf(1, 1, 10), closeTo(10, 1e-9));
      // Halfway in crop width: 1 / ((1 + 0.1) / 2).
      expect(CameraZoom.factorOf(0.5, 1, 10), closeTo(1 / 0.55, 1e-9));
      expect(CameraZoom.zoomOf(1 / 0.55, 1, 10), closeTo(0.5, 1e-9));
      expect(CameraZoom.zoomOf(3, 2, 2), 0);
    });

    test(
      'a switch starts the new camera at 1x with no exposure bias',
      () async {
        final session = await FakeCameraSessions(minZoomFactor: 0.5).open();
        await session.setZoomFactor(4);
        await session.setExposure(0.5);
        await session.switchCamera();
        expect(session.value.value.zoomFactor, 1);
        expect(session.value.value.exposure, 0);
      },
    );
  });

  group('the app in the background', () {
    late TestWidgetsFlutterBinding binding;
    setUp(() {
      binding = TestWidgetsFlutterBinding.ensureInitialized();
      _show(binding);
    });
    tearDown(() => _show(binding));
    Future<void> settle() => Future<void>.delayed(Duration.zero);

    test('hidden, the camera is let go; shown, it is taken back', () async {
      final session = await FakeCameraSessions().open() as FakeCameraSession;
      expect(session.isReleased, isFalse);
      _hide(binding);
      await settle();
      expect(session.isReleased, isTrue);
      _show(binding);
      await settle();
      expect(session.isReleased, isFalse);
      expect(session.value.value.awaitingFrames, isFalse);
    });

    test('a recording stops when the app hides', () async {
      final session = await FakeCameraSessions().open();
      await session.startRecording(outputPath: '${directory.path}/v.mp4');
      _hide(binding);
      await settle();
      expect(session.value.value.isRecording, isFalse);
    });

    test('paused by the host meanwhile, it stays let go when shown', () async {
      final session = await FakeCameraSessions().open() as FakeCameraSession;
      _hide(binding);
      await settle();
      await session.pause();
      _show(binding);
      await settle();
      expect(session.isReleased, isTrue);
      await session.resume();
      expect(session.isReleased, isFalse);
    });

    test(
      'resumed by the host while hidden, it opens only when shown',
      () async {
        final session = await FakeCameraSessions().open() as FakeCameraSession;
        await session.pause();
        _hide(binding);
        await settle();
        await session.resume();
        expect(session.isReleased, isTrue);
        expect(session.value.value.awaitingFrames, isTrue);
        _show(binding);
        await settle();
        expect(session.isReleased, isFalse);
      },
    );
  });
}

// The app's lifecycle moves a step at a time.
void _hide(TestWidgetsFlutterBinding binding) {
  if (binding.lifecycleState == AppLifecycleState.hidden) return;
  binding
    ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
    ..handleAppLifecycleStateChanged(AppLifecycleState.hidden);
}

void _show(TestWidgetsFlutterBinding binding) {
  switch (binding.lifecycleState) {
    case AppLifecycleState.resumed:
      return;
    case AppLifecycleState.hidden:
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    case _:
  }
  binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}
