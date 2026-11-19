import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_capture/src/camera/camera_session.dart';
import 'package:mpx_capture/src/job/capture_job.dart';
import 'package:mpx_capture/src/round/round_video_recorder.dart';

/// What a camera ownership contract run needs: a session opener and a round
/// video recorder over the same camera, and a directory for outputs. Camera
/// and microphone access must be granted.
final class CameraOwnershipHarness {
  /// Creates a harness.
  const CameraOwnershipHarness({
    required this.sessions,
    required this.recorder,
    required this.outputDirectory,
  });

  /// The session opener.
  final CameraSessions sessions;

  /// The round video recorder.
  final RoundVideoRecorder recorder;

  /// An existing, writable directory.
  final String outputDirectory;
}

/// The one-owner rule between camera sessions and round video recordings:
/// whichever opens the camera takes it over from the other, which ends
/// cleanly (a session turns closed; a recording fails as taken over and its
/// file is gone).
abstract final class CameraOwnershipContract {
  /// Runs it as a test group. [create] builds a fresh harness for each test.
  static void run(CameraOwnershipHarness Function() create) {
    group('Camera ownership contract', () {
      late CameraOwnershipHarness harness;
      final sessions = <CameraSession>[];
      final recordings = <RoundVideoRecording>[];

      setUp(() => harness = create());
      tearDown(() async {
        for (final recording in recordings) {
          await recording.job.cancel();
        }
        for (final session in sessions) {
          await session.dispose();
        }
        recordings.clear();
        sessions.clear();
      });

      Future<CameraSession> open() async {
        final session = await harness.sessions.open();
        sessions.add(session);
        return session;
      }

      Future<RoundVideoRecording> record(String name) async {
        final recording = await harness.recorder.start(
          outputPath: '${harness.outputDirectory}/$name.mp4',
        );
        recordings.add(recording);
        return recording;
      }

      test('a round video recording takes the camera from a session', () async {
        final session = await open();
        expect(session.value.value.state, CameraSessionState.available);
        final recording = await record('ownership-a');
        expect(session.value.value.state, CameraSessionState.closed);
        await expectLater(
          session.capturePhoto(
            outputPath: '${harness.outputDirectory}/ownership-a.jpg',
          ),
          throwsA(isA<CaptureFailed>()),
        );
        expect(recording.job.isDone, isFalse);
        await recording.stop();
      });

      test('a session takes the camera from a round video recording', () async {
        final recording = await record('ownership-b');
        final session = await open();
        await expectLater(
          recording.job.output,
          throwsA(
            isA<CaptureFailed>().having(
              (e) => e.message,
              'message',
              contains('taken over'),
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(
          File('${harness.outputDirectory}/ownership-b.mp4').existsSync(),
          isFalse,
        );
        expect(session.value.value.state, CameraSessionState.available);
        final photo = await session.capturePhoto(
          outputPath: '${harness.outputDirectory}/ownership-b.jpg',
        );
        expect(photo.size, greaterThan(0));
      });
    });
  }
}
