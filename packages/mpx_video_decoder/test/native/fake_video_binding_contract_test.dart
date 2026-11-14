import 'dart:convert';
import 'dart:typed_data';

import 'package:mpx_video_decoder/src/binding/binding.dart';
import 'package:mpx_video_decoder/testing.dart';

void main() {
  final valid = Uint8List.fromList(utf8.encode('a video'));
  const info = VideoInfo(
    width: 320,
    height: 240,
    duration: Duration(milliseconds: 500),
    frameRate: 10,
    hasAlpha: true,
  );

  VideoBindingContract.run(() {
    const elsewhere = VideoSource.file('/media/a-video.mp4');
    final fake = FakeVideoBinding()
      ..accept(valid, info, frameCount: 5)
      ..acceptSource(elsewhere, info, frameCount: 5);
    return VideoBindingHarness(
      binding: fake,
      validBytes: valid,
      expectedInfo: info,
      frameCount: 5,
      malformedBytes: Uint8List.fromList(utf8.encode('not a video')),
      validElsewhere: elsewhere,
      unavailable: () =>
          FakeVideoBinding(availability: VideoAvailability.missingLibrary),
    );
  });
}
