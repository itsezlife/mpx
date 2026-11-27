import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_capture/mpx_capture.dart';
import 'package:mpx_capture/testing.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';

MediaPreparationHarness _harness(PreparationIntent intent) {
  final directory = Directory.systemTemp.createTempSync('mpx_prep_contract');
  File('${directory.path}/clip.mp4').writeAsBytesSync([1, 2, 3]);
  return MediaPreparationHarness(
    preparation: CaptureMediaPreparation(
      preparer: MediaPreparer(
        codec: FakePreparationCodec(
          stills: {
            '/photo.jpg': const StillSource(
              dimensions: MediaDimensions(4032, 3024),
              byteSize: 3000000,
              mimeType: 'image/jpeg',
            ),
          },
          videos: {
            '${directory.path}/clip.mp4': const MediaDimensions(1280, 720),
          },
        ),
        transcoder: FakeTranscoder(
          sources: {
            '${directory.path}/clip.mp4': const SourceVideo(
              dimensions: MediaDimensions(1280, 720),
              duration: Duration(seconds: 2),
              codec: SourceCodec.h264,
              videoBitrate: 4000000,
            ),
          },
        ),
        outputDirectory: directory.path,
      ),
      policy: PreparationPolicy.$IOS,
    ),
    input: intent is PreparationIntent$Video
        ? PreparationInput('${directory.path}/clip.mp4')
        : const PreparationInput('/photo.jpg'),
    intent: intent,
    unpreparable: const PreparationInput('/missing'),
    dispose: () async => directory.deleteSync(recursive: true),
  );
}

void main() {
  group('as photo', () {
    MediaPreparationContract.run(
      () => _harness(const PreparationIntent.photo()),
    );
  });
  group('as video', () {
    MediaPreparationContract.run(
      () => _harness(
        const PreparationIntent.video(preset: CompressionPreset.low),
      ),
    );
  });
}
