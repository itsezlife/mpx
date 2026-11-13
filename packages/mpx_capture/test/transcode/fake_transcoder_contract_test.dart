import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_capture/mpx_capture.dart';
import 'package:mpx_capture/testing.dart';
import 'package:mpx_core/mpx_core.dart';

void main() {
  group('FakeTranscoder', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('mpx_capture_'));
    tearDown(() => temp.deleteSync(recursive: true));

    TranscoderContract.run(() {
      final source = '${temp.path}/source.mp4';
      final notAVideo = '${temp.path}/notes.txt';
      File(source).writeAsBytesSync([0]);
      File(notAVideo).writeAsStringSync('text');
      return TranscoderHarness(
        transcoder: FakeTranscoder(
          sources: {
            source: const SourceVideo(
              dimensions: MediaDimensions(1920, 1080),
              duration: Duration(seconds: 3),
              codec: SourceCodec.h264,
              videoBitrate: 8000000,
            ),
          },
        ),
        source: source,
        notAVideo: notAVideo,
        outputDirectory: temp.path,
      );
    });

    test('compresses by the plan of the preset', () async {
      const source = SourceVideo(
        dimensions: MediaDimensions(1920, 1080),
        duration: Duration(seconds: 2),
        codec: SourceCodec.h264,
        videoBitrate: 8000000,
      );
      final transcoder = FakeTranscoder(sources: {'/in.mp4': source});
      final output = await transcoder
          .compress(
            TranscodeRequest(
              sourcePath: '/in.mp4',
              outputPath: '${temp.path}/out.mp4',
              preset: CompressionPreset.high,
            ),
          )
          .output;
      expect(transcoder.plans.single, CompressionPreset.high.planFor(source));
      expect(output.dimensions, const MediaDimensions(1280, 720));
      expect(output.headerRewritten, isTrue);
    });
  });
}
