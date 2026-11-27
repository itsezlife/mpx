import 'dart:math' as math;

import 'package:mpx_core/src/identity/media_descriptor.dart';

/// The table of compression steps a video is sent at.
///
/// One table for every platform: each step caps the long side of the frame
/// and sets the H.264 video bitrate and the AAC audio bitrate and channel
/// count. The preparer turns a step and a source into the concrete output,
/// whose bitrate never exceeds the source's.
///
/// [shared] are the five steps every platform knows; [tiny] is the 432 px
/// step only the Android preparation policy offers, below [veryLow].
///
/// The step's [name] is its stable identity in a stored preparation intent
/// (`PreparationEncoding`): a step is never renamed, only added.
enum CompressionPreset {
  /// 432 px, at most 750 kbps video, 32 kbps mono audio.
  tiny(maxSide: 432, videoKbps: 750, audioKbps: 32, audioChannels: 1),

  /// 480 px, 400 kbps video, 32 kbps mono audio.
  veryLow(maxSide: 480, videoKbps: 400, audioKbps: 32, audioChannels: 1),

  /// 640 px, 700 kbps video, 32 kbps mono audio.
  low(maxSide: 640, videoKbps: 700, audioKbps: 32, audioChannels: 1),

  /// 848 px, 1600 kbps video, 64 kbps stereo audio.
  medium(maxSide: 848, videoKbps: 1600, audioKbps: 64, audioChannels: 2),

  /// 1280 px, 3000 kbps video, 64 kbps stereo audio.
  high(maxSide: 1280, videoKbps: 3000, audioKbps: 64, audioChannels: 2),

  /// 1920 px, 6600 kbps video, 64 kbps stereo audio.
  veryHigh(maxSide: 1920, videoKbps: 6600, audioKbps: 64, audioChannels: 2);

  const CompressionPreset({
    required this.maxSide,
    required this.videoKbps,
    required this.audioKbps,
    required this.audioChannels,
  });

  /// The longest side of the output frame, in pixels.
  final int maxSide;

  /// The video bitrate in kilobits (1000 bits) per second.
  final int videoKbps;

  /// The audio bitrate in kilobits (1000 bits) per second.
  final int audioKbps;

  /// The audio channel count.
  final int audioChannels;

  /// [videoKbps] in bits per second.
  int get videoBitrate => videoKbps * 1000;

  /// [audioKbps] in bits per second.
  int get audioBitrate => audioKbps * 1000;

  /// The five steps every platform knows, [veryLow] to [veryHigh].
  static const List<CompressionPreset> shared = [
    veryLow,
    low,
    medium,
    high,
    veryHigh,
  ];

  /// The [shared] steps worth offering for a source of [dimensions]: every
  /// step below its long side, and the first step that holds it whole. A
  /// step above that one would only re-encode at the same size with more
  /// bits. A platform's own offer comes from its preparation policy.
  static List<CompressionPreset> offeredFor(MediaDimensions dimensions) {
    final longSide = math.max(dimensions.width, dimensions.height);
    final offered = <CompressionPreset>[];
    for (final preset in shared) {
      offered.add(preset);
      if (preset.maxSide >= longSide) break;
    }
    return offered;
  }
}
