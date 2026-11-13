import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_capture/src/job/capture_job.dart';
import 'package:mpx_capture/src/round/round_video_recorder.dart';
import 'package:mpx_core/mpx_core.dart';

/// What a [RoundVideoRecorder] contract run needs: a recorder with camera
/// and microphone allowed, a directory for outputs and a way to let
/// recording time pass.
final class RoundVideoRecorderHarness {
  /// Creates a harness.
  ///
  /// [elapse] lets at least a few frames record (a few milliseconds for a
  /// fake, about half a second for a camera).
  const RoundVideoRecorderHarness({
    required this.recorder,
    required this.outputDirectory,
    required this.elapse,
  });

  /// The recorder under test; access must already be granted.
  final RoundVideoRecorder recorder;

  /// An existing, writable directory.
  final String outputDirectory;

  /// Lets recording time pass.
  final Future<void> Function() elapse;
}

/// The contract every [RoundVideoRecorder] meets; see its documentation.
abstract final class RoundVideoRecorderContract {
  /// Runs it as a test group. [create] builds a fresh harness for each test.
  static void run(RoundVideoRecorderHarness Function() create) {
    group('RoundVideoRecorder contract', () {
      late RoundVideoRecorderHarness harness;
      final recordings = <RoundVideoRecording>[];
      var outputs = 0;

      setUp(() => harness = create());
      tearDown(() async {
        for (final recording in recordings) {
          await recording.job.cancel();
        }
        recordings.clear();
      });

      Future<RoundVideoRecording> start([
        RoundVideoConfig config = const RoundVideoConfig(),
      ]) async {
        final recording = await harness.recorder.start(
          outputPath: '${harness.outputDirectory}/round-${outputs++}.mp4',
          config: config,
        );
        recordings.add(recording);
        return recording;
      }

      test('access is granted', () async {
        expect(await harness.recorder.requestPermission(), isTrue);
      });

      test('records a square file and reports it on stop', () async {
        final recording = await start();
        final reports = <CaptureProgress>[];
        recording.job.progress.listen(reports.add);
        expect(recording.config, const RoundVideoConfig());
        expect(CameraFacing.values, contains(recording.camera));
        await harness.elapse();
        final output = await recording.stop();

        expect(File(output.path).lengthSync(), output.size);
        expect(output.size, greaterThan(0));
        expect(output.dimensions, const MediaDimensions(384, 384));
        expect(output.duration, greaterThan(Duration.zero));
        expect(output.duration, lessThan(const Duration(seconds: 60)));

        expect(reports, isNotEmpty);
        expect(reports.last.isFinal, isTrue);
        expect(reports.last.finalSize, output.size);
        expect(reports.last.fraction, lessThan(1));
        for (var i = 1; i < reports.length; i++) {
          expect(
            reports[i].position,
            greaterThanOrEqualTo(reports[i - 1].position),
          );
          expect(
            reports[i].bytesWritten,
            greaterThanOrEqualTo(reports[i - 1].bytesWritten),
          );
        }
      });

      test('paused time is not recorded', () async {
        final recording = await start();
        await harness.elapse();
        await recording.pause();
        expect(recording.isPaused, isTrue);
        // Frames already on their way may still land; then time stands.
        await harness.elapse();
        final paused = recording.job.latest?.position ?? Duration.zero;
        await harness.elapse();
        expect(recording.job.latest?.position ?? Duration.zero, paused);

        await recording.resume();
        expect(recording.isPaused, isFalse);
        await harness.elapse();
        expect(recording.job.latest!.position, greaterThan(paused));
        final output = await recording.stop();
        expect(output.size, greaterThan(0));
      });

      test('switching the camera keeps the recording', () async {
        final recording = await start();
        await harness.elapse();
        final before = recording.camera;
        final after = await recording.switchCamera();
        expect(recording.camera, after);
        expect(CameraFacing.values, contains(before));
        await harness.elapse();
        final output = await recording.stop();
        expect(output.size, greaterThan(0));
      });

      test('reaching the longest allowed time finishes the file', () async {
        const max = Duration(seconds: 1);
        final recording = await start(const RoundVideoConfig(maxDuration: max));
        final output = await recording.job.output;
        expect(output.duration, greaterThanOrEqualTo(max * 0.9));
        expect(output.duration, lessThanOrEqualTo(max * 1.1));
        expect(recording.job.latest!.fraction, closeTo(1, 0.1));
      });

      test('cancel discards the file', () async {
        final recording = await start();
        await harness.elapse();
        final path = '${harness.outputDirectory}/round-${outputs - 1}.mp4';
        await recording.job.cancel();
        await expectLater(
          recording.job.output,
          throwsA(isA<CaptureCancelled>()),
        );
        expect(File(path).existsSync(), isFalse);
      });

      test('controls after the end change nothing', () async {
        final recording = await start();
        await harness.elapse();
        final output = await recording.stop();
        await recording.pause();
        await recording.switchCamera();
        await recording.job.cancel();
        expect(await recording.stop(), output);
        expect(File(output.path).existsSync(), isTrue);
      });
    });
  }
}
