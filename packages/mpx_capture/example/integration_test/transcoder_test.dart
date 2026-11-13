import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mpx_capture/mpx_capture.dart';
import 'package:mpx_capture/testing.dart';

/// The platform transcoder against the shared contract, on a real device,
/// with the bundled 960 x 540 H.264 + AAC clip as the source.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late String source;
  late String notAVideo;

  setUpAll(() async {
    temp = Directory.systemTemp.createTempSync('mpx_capture_it_');
    final bytes = await rootBundle.load('assets/source.mp4');
    source = '${temp.path}/source.mp4';
    File(source).writeAsBytesSync(bytes.buffer.asUint8List());
    notAVideo = '${temp.path}/notes.txt';
    File(notAVideo).writeAsStringSync('not a video');
  });

  tearDownAll(() => temp.deleteSync(recursive: true));

  TranscoderContract.run(
    () => TranscoderHarness(
      transcoder: const PlatformTranscoder(),
      source: source,
      notAVideo: notAVideo,
      outputDirectory: temp.path,
      reprobeOutputs: true,
    ),
  );

  test('a source that fits the step is remuxed, not re-encoded', () async {
    const transcoder = PlatformTranscoder();
    final probed = await transcoder.probe(source);
    final plan = CompressionPreset.veryHigh.planFor(probed);
    expect(plan.passthrough, isTrue, reason: '$probed');
    final output = await transcoder
        .compress(
          TranscodeRequest(
            sourcePath: source,
            outputPath: '${temp.path}/remux.mp4',
            preset: CompressionPreset.veryHigh,
          ),
        )
        .output;
    expect(output.reencoded, isFalse);
    expect(output.dimensions, probed.dimensions);
    expect(await transcoder.probe(output.path), isA<SourceVideo>());
  });

  test('a low step keeps the audio track', () async {
    const transcoder = PlatformTranscoder();
    final output = await transcoder
        .compress(
          TranscodeRequest(
            sourcePath: source,
            outputPath: '${temp.path}/mono.mp4',
            preset: CompressionPreset.low,
          ),
        )
        .output;
    final probed = await transcoder.probe(output.path);
    expect(probed.hasAudio, isTrue);
    expect(probed.dimensions.width, lessThanOrEqualTo(640));
  });
}
