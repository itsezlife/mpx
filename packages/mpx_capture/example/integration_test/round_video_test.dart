import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mpx_capture/mpx_capture.dart';
import 'package:mpx_capture/testing.dart';

/// The platform round video recorder against the shared contract. Needs a
/// camera and a microphone, and asks for access on the first run: grant it,
/// then run again if the first run timed out on the prompt.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;

  setUpAll(() async {
    temp = Directory.systemTemp.createTempSync('mpx_round_it_');
    expect(
      await const PlatformRoundVideoRecorder().requestPermission(),
      isTrue,
      reason: 'camera and microphone access',
    );
  });

  tearDownAll(() => temp.deleteSync(recursive: true));

  RoundVideoRecorderContract.run(
    () => RoundVideoRecorderHarness(
      recorder: const PlatformRoundVideoRecorder(),
      outputDirectory: temp.path,
      elapse: () => Future<void>.delayed(const Duration(milliseconds: 700)),
    ),
  );

  test('the file is a square H.264 video', () async {
    const recorder = PlatformRoundVideoRecorder();
    final recording = await recorder.start(
      outputPath: '${temp.path}/probe.mp4',
    );
    await Future<void>.delayed(const Duration(seconds: 2));
    final output = await recording.stop();
    final probed = await const PlatformTranscoder().probe(output.path);
    expect(probed.codec, SourceCodec.h264);
    expect(probed.dimensions.width, probed.dimensions.height);
    expect(probed.hasAudio, isTrue);
  });
}
