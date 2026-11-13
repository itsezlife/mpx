import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_capture/mpx_capture.dart';
import 'package:mpx_capture/testing.dart';

void main() {
  group('FakeRoundVideoRecorder', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('mpx_round_'));
    tearDown(() => temp.deleteSync(recursive: true));

    RoundVideoRecorderContract.run(
      () => RoundVideoRecorderHarness(
        recorder: FakeRoundVideoRecorder(),
        outputDirectory: temp.path,
        elapse: () => Future<void>.delayed(const Duration(milliseconds: 20)),
      ),
    );

    test('start without access fails', () async {
      final recorder = FakeRoundVideoRecorder(permitted: false);
      expect(await recorder.requestPermission(), isFalse);
      await expectLater(
        recorder.start(outputPath: '${temp.path}/x.mp4'),
        throwsA(isA<CapturePermissionDenied>()),
      );
    });

    test('a single camera stays on switch', () async {
      final recorder = FakeRoundVideoRecorder(
        cameras: const {CameraFacing.back},
      );
      final recording = await recorder.start(outputPath: '${temp.path}/x.mp4');
      expect(recording.camera, CameraFacing.back);
      expect(await recording.switchCamera(), CameraFacing.back);
      await recording.job.cancel();
    });
  });
}
