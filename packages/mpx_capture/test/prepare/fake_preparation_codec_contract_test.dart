import 'dart:io';

import 'package:mpx_capture/mpx_capture.dart';
import 'package:mpx_capture/testing.dart';
import 'package:mpx_core/mpx_core.dart';

void main() {
  final directory = Directory.systemTemp.createTempSync('mpx_codec_contract');
  PreparationCodecContract.run(
    () => PreparationCodecHarness(
      codec: FakePreparationCodec(
        stills: {
          '/media/photo.jpg': const StillSource(
            dimensions: MediaDimensions(4032, 3024),
            byteSize: 2500000,
            mimeType: 'image/jpeg',
          ),
        },
        videos: {'/media/clip.mp4': const MediaDimensions(1920, 1080)},
      ),
      jpeg: '/media/photo.jpg',
      video: '/media/clip.mp4',
      notMedia: '/media/notes.txt',
      outputDirectory: directory.path,
    ),
  );
}
