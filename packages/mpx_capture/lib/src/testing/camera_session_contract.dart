import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_capture/src/camera/camera_session.dart';
import 'package:mpx_capture/src/job/capture_job.dart';

/// What a [CameraSessions] contract run needs: the opener and a directory
/// for captures. The device's camera access must be granted.
final class CameraSessionHarness {
  /// Creates a harness.
  const CameraSessionHarness({
    required this.sessions,
    required this.outputDirectory,
    this.recordFor = const Duration(milliseconds: 300),
  });

  /// The opener under test.
  final CameraSessions sessions;

  /// An existing, writable directory.
  final String outputDirectory;

  /// How long the recording test records.
  final Duration recordFor;
}

/// The contract every [CameraSessions] and its [CameraSession]s meet; see
/// their documentation.
abstract final class CameraSessionContract {
  /// Runs it as a test group. [create] builds a fresh harness for each test;
  /// every session it opens is disposed after the test.
  static void run(CameraSessionHarness Function() create) {
    group('CameraSession contract', () {
      late CameraSessionHarness harness;
      final opened = <CameraSession>[];
      var outputs = 0;

      setUp(() => harness = create());
      tearDown(() async {
        for (final session in opened) {
          await session.dispose();
        }
        opened.clear();
      });

      Future<CameraSession> open({int? frameRateCap}) async {
        final session = await harness.sessions.open(frameRateCap: frameRateCap);
        opened.add(session);
        return session;
      }

      String nextOutput(String extension) =>
          '${harness.outputDirectory}/camera-contract-${outputs++}.$extension';

      test('opens available with a preview size and the asked cap', () async {
        final session = await open(frameRateCap: 30);
        final value = session.value.value;
        expect(value.state, CameraSessionState.available);
        expect(value.previewSize, isNotNull);
        expect(value.frameRateCap, 30);
        expect(value.isPaused, isFalse);
        expect(value.isRecording, isFalse);
      });

      test('the frame-rate cap changes and lifts', () async {
        final session = await open(frameRateCap: 30);
        await session.setFrameRateCap(null);
        expect(session.value.value.frameRateCap, isNull);
        await session.setFrameRateCap(30);
        expect(session.value.value.frameRateCap, 30);
        expect(session.value.value.state, CameraSessionState.available);
      });

      test('a photo lands in the output file', () async {
        final session = await open();
        final path = nextOutput('jpg');
        final photo = await session.capturePhoto(outputPath: path);
        expect(photo.path, path);
        expect(File(path).lengthSync(), photo.size);
        expect(photo.size, greaterThan(0));
      });

      test('a recording lands in the output file', () async {
        final session = await open();
        final path = nextOutput('mp4');
        await session.startRecording(outputPath: path);
        expect(session.value.value.isRecording, isTrue);
        await Future<void>.delayed(harness.recordFor);
        final video = await session.stopRecording();
        expect(session.value.value.isRecording, isFalse);
        expect(video.path, path);
        expect(File(path).lengthSync(), video.size);
        expect(video.duration, greaterThanOrEqualTo(Duration.zero));
      });

      test('stopping without a recording fails', () async {
        final session = await open();
        await expectLater(
          session.stopRecording(),
          throwsA(isA<CaptureFailed>()),
        );
      });

      test('pause and resume', () async {
        final session = await open();
        await session.pause();
        expect(session.value.value.isPaused, isTrue);
        await expectLater(
          session.capturePhoto(outputPath: nextOutput('jpg')),
          throwsA(isA<CaptureFailed>()),
          reason: 'a paused camera takes no photo',
        );
        await session.resume();
        expect(session.value.value.isPaused, isFalse);
      });

      test('switching answers the camera in use', () async {
        final session = await open();
        final before = session.value.value.facing;
        final after = await session.switchCamera();
        expect(session.value.value.facing, after);
        if (!session.value.value.canSwitchCamera) expect(after, before);
      });

      test('the flash mode is kept', () async {
        final session = await open();
        await session.setFlash(CameraFlash.auto);
        expect(session.value.value.flash, CameraFlash.auto);
      });

      test('a second open takes the camera over', () async {
        final first = await open();
        final second = await open();
        expect(first.value.value.state, CameraSessionState.closed);
        expect(second.value.value.state, CameraSessionState.available);
        await expectLater(
          first.capturePhoto(outputPath: nextOutput('jpg')),
          throwsA(isA<CaptureFailed>()),
        );
      });

      test('dispose closes, and is idempotent', () async {
        final session = await open();
        await session.dispose();
        await session.dispose();
        expect(session.value.value.state, CameraSessionState.closed);
        await expectLater(
          session.switchCamera(),
          throwsA(isA<CaptureFailed>()),
        );
      });
    });
  }
}
