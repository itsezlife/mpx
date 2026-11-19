import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:mpx_core/mpx_core.dart';

/// The table of compression steps a video is sent at.
///
/// One table for every platform: each step caps the long side of the frame
/// and sets the H.264 video bitrate and the AAC audio bitrate and channel
/// count. Every encoder writes a keyframe each second. [planFor] turns a step
/// and a source into the concrete output; the output bitrate never exceeds
/// the source's.
///
/// [shared] are the five steps every platform knows; [tiny] is the 432 px
/// step only the Android preparation policy offers, below [veryLow].
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

  /// What compressing [source] at this step produces.
  ///
  /// The long side is scaled down to [maxSide] (never up), both sides rounded
  /// to even pixels as H.264 needs. The video bitrate is [videoBitrate] or
  /// the source's, whichever is lower. An H.264 source whose size and bitrate
  /// would not change is passed through: remuxed, not re-encoded.
  CompressionPlan planFor(SourceVideo source) {
    final size = _outputSize(source.dimensions);
    final sourceBitrate = source.videoBitrate;
    final bitrate = sourceBitrate == null
        ? videoBitrate
        : math.min(videoBitrate, sourceBitrate);
    return CompressionPlan(
      size: size,
      videoBitrate: bitrate,
      audioBitrate: audioBitrate,
      audioChannels: audioChannels,
      passthrough:
          source.codec == SourceCodec.h264 &&
          size == source.dimensions &&
          sourceBitrate != null &&
          sourceBitrate <= videoBitrate,
    );
  }

  MediaDimensions _outputSize(MediaDimensions source) {
    final longSide = math.max(source.width, source.height);
    final scale = longSide <= maxSide ? 1.0 : maxSide / longSide;
    return MediaDimensions(
      _even(source.width * scale),
      _even(source.height * scale),
    );
  }

  // Rounds to the nearest pixel, then down to even; never below 2.
  static int _even(double side) => math.max(2, side.round() & ~1);
}

/// The video codec of a source, as far as compression cares.
enum SourceCodec {
  /// H.264 / AVC: the codec the presets write, so a source can pass through.
  h264,

  /// H.265 / HEVC.
  hevc,

  /// Any other codec.
  other,
}

/// What a [Transcoder] reads from a video before compressing it.
@immutable
final class SourceVideo {
  /// Describes a source video.
  const SourceVideo({
    required this.dimensions,
    required this.duration,
    required this.codec,
    this.videoBitrate,
    this.hasAudio = true,
  });

  /// The frame size as displayed, after the track's rotation.
  final MediaDimensions dimensions;

  /// The playing time.
  final Duration duration;

  /// The video codec.
  final SourceCodec codec;

  /// The video track's bitrate in bits per second, when the container tells.
  final int? videoBitrate;

  /// Whether the source has an audio track.
  final bool hasAudio;

  @override
  bool operator ==(Object other) =>
      other is SourceVideo &&
      other.dimensions == dimensions &&
      other.duration == duration &&
      other.codec == codec &&
      other.videoBitrate == videoBitrate &&
      other.hasAudio == hasAudio;

  @override
  int get hashCode =>
      Object.hash(dimensions, duration, codec, videoBitrate, hasAudio);

  @override
  String toString() =>
      'SourceVideo($dimensions, $duration, $codec, '
      '${videoBitrate ?? '?'} bps, audio: $hasAudio)';
}

/// The concrete output of one compression: a [CompressionPreset] applied to
/// one [SourceVideo].
@immutable
final class CompressionPlan {
  /// Creates a plan.
  const CompressionPlan({
    required this.size,
    required this.videoBitrate,
    required this.audioBitrate,
    required this.audioChannels,
    required this.passthrough,
  });

  /// The output frame size as displayed.
  final MediaDimensions size;

  /// The video bitrate in bits per second.
  final int videoBitrate;

  /// The audio bitrate in bits per second.
  final int audioBitrate;

  /// The audio channel count.
  final int audioChannels;

  /// Whether the source is remuxed as it is instead of re-encoded.
  final bool passthrough;

  @override
  bool operator ==(Object other) =>
      other is CompressionPlan &&
      other.size == size &&
      other.videoBitrate == videoBitrate &&
      other.audioBitrate == audioBitrate &&
      other.audioChannels == audioChannels &&
      other.passthrough == passthrough;

  @override
  int get hashCode =>
      Object.hash(size, videoBitrate, audioBitrate, audioChannels, passthrough);

  @override
  String toString() =>
      'CompressionPlan($size, $videoBitrate bps, $audioBitrate bps x '
      '$audioChannels, passthrough: $passthrough)';
}
