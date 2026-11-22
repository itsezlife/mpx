/// The three committed fixtures and the skip rule for tests that need the
/// native library.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:mpx_video_decoder/src/binding/binding.dart';

/// A committed fixture and what its generator command (README) says it is.
final class Fixture {
  const Fixture(
    this.file, {
    required this.width,
    required this.height,
    required this.frames,
    required this.frameRate,
    required this.hasAlpha,
  });

  final String file;
  final int width;
  final int height;
  final int frames;
  final double frameRate;
  final bool hasAlpha;

  /// Where the fixture is, absolute.
  String get path => File('native/probe/fixtures/$file').absolute.path;

  Uint8List get bytes => File(path).readAsBytesSync();
}

const mp4 = Fixture(
  'h264_320x240_30fps_2s.mp4',
  width: 320,
  height: 240,
  frames: 60,
  frameRate: 30,
  hasAlpha: false,
);

const webm = Fixture(
  'vp9_alpha_512x512_30fps_1s.webm',
  width: 512,
  height: 512,
  frames: 30,
  frameRate: 30,
  hasAlpha: true,
);

const gif = Fixture(
  'gif_64x48_10fps_1s.gif',
  width: 64,
  height: 48,
  frames: 10,
  frameRate: 10,
  hasAlpha: false,
);

const fixtures = [mp4, webm, gif];

/// A 320x240 picture whose container turns it a quarter clockwise to show:
/// red top-left quarter on blue, so shown upright the red is top-right. Not
/// in [fixtures]: its size is the shown one.
const rotated = Fixture(
  'h264_320x240_rot90_30fps_1s.mp4',
  width: 240,
  height: 320,
  frames: 30,
  frameRate: 30,
  hasAlpha: false,
);

/// Why the native tests cannot run here, or null when they can.
String? nativeSkipReason(VideoBinding binding) => binding.isAvailable
    ? null
    : 'the native library is not bundled (${binding.availability}); build '
          'it with packages/mpx_video_decoder/native/recipe/build.sh';
