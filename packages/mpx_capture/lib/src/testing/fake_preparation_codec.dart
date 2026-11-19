import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:mpx_capture/src/job/capture_job.dart';
import 'package:mpx_capture/src/prepare/preparation_codec.dart';
import 'package:mpx_capture/src/prepare/preparation_policy.dart';
import 'package:mpx_core/mpx_core.dart';

/// One `encodeStill` call a [FakePreparationCodec] took.
@immutable
final class FakeStillEncode {
  /// Records a call.
  const FakeStillEncode({
    required this.path,
    required this.maxSide,
    required this.quality,
    required this.progressive,
    required this.outputPath,
  });

  /// The source.
  final String path;

  /// The long side asked for.
  final int maxSide;

  /// The JPEG quality asked for.
  final int quality;

  /// Whether a progressive JPEG was asked for.
  final bool progressive;

  /// The file written, or null for an encode into memory.
  final String? outputPath;

  @override
  String toString() =>
      'FakeStillEncode($path, $maxSide px at $quality'
      '${progressive ? ', progressive' : ''} -> ${outputPath ?? 'memory'})';
}

/// A [PreparationCodec] over stills and videos it is told about, writing
/// stand-in JPEGs.
///
/// [stills] maps a path to what [probeStill] answers; [videos] maps a path
/// to a video's frame size for [videoThumbnail]. Any other path fails with
/// `CaptureFailed`. An encode fits the source into the asked side and
/// writes [encodedSize] bytes (by default a tenth of a byte per pixel and
/// quality point); every call waits [delay]. Meets `PreparationCodecContract`.
final class FakePreparationCodec implements PreparationCodec {
  /// Creates a fake that knows [stills] and [videos].
  FakePreparationCodec({
    Map<String, StillSource>? stills,
    Map<String, MediaDimensions>? videos,
    this.delay = Duration.zero,
  }) : stills = {...?stills},
       videos = {...?videos};

  /// What [probeStill] answers, by path.
  final Map<String, StillSource> stills;

  /// The frame size of each video, by path.
  final Map<String, MediaDimensions> videos;

  /// The wait in every call.
  Duration delay;

  /// The size of an encoded JPEG of [size] at [quality].
  int Function(MediaDimensions size, int quality) encodedSize =
      _defaultEncodedSize;

  /// Every [probeStill] path, in order.
  final List<String> probes = [];

  /// Every [encodeStill] call, in order.
  final List<FakeStillEncode> encodes = [];

  /// Every [videoThumbnail] call as (path, side, quality), in order.
  final List<(String, int, int)> posters = [];

  /// The most calls that ran at once.
  int maxConcurrent = 0;
  int _running = 0;

  static int _defaultEncodedSize(MediaDimensions size, int quality) =>
      math.max(1, size.width * size.height * quality ~/ 1000);

  @override
  Future<StillSource> probeStill(String path) => _call(() {
    probes.add(path);
    return stills[path] ?? (throw CaptureFailed('not a still: $path'));
  });

  @override
  Future<EncodedStill> encodeStill(
    String path, {
    required int maxSide,
    required int quality,
    bool progressive = false,
    String? outputPath,
  }) => _call(() {
    encodes.add(
      FakeStillEncode(
        path: path,
        maxSide: maxSide,
        quality: quality,
        progressive: progressive,
        outputPath: outputPath,
      ),
    );
    final source = stills[path];
    if (source == null) throw CaptureFailed('not a still: $path');
    return _write(_fit(source.dimensions, maxSide), quality, outputPath);
  });

  @override
  Future<EncodedStill> videoThumbnail(String path, ThumbnailSpec spec) =>
      _call(() {
        posters.add((path, spec.side, spec.quality));
        final frame = videos[path];
        if (frame == null) throw CaptureFailed('not a video: $path');
        return _write(_fit(frame, spec.side), spec.quality, null);
      });

  EncodedStill _write(MediaDimensions size, int quality, String? outputPath) {
    final byteSize = encodedSize(size, quality);
    if (outputPath != null) {
      File(outputPath).writeAsBytesSync(Uint8List(byteSize));
      return EncodedStill(dimensions: size, byteSize: byteSize);
    }
    // Stand-in bytes that name what they stand for, at the reported size.
    final label = utf8.encode('jpeg ${size.width}x${size.height} q$quality');
    final bytes = Uint8List(byteSize)
      ..setRange(0, math.min(label.length, byteSize), label);
    return EncodedStill(dimensions: size, byteSize: byteSize, bytes: bytes);
  }

  Future<T> _call<T>(T Function() body) async {
    _running++;
    maxConcurrent = math.max(maxConcurrent, _running);
    try {
      await Future<void>.delayed(delay);
      return body();
    } finally {
      _running--;
    }
  }

  static MediaDimensions _fit(MediaDimensions size, int side) {
    final longSide = math.max(size.width, size.height);
    if (longSide <= side) return size;
    final scale = side / longSide;
    return MediaDimensions(
      math.max(1, (size.width * scale).round()),
      math.max(1, (size.height * scale).round()),
    );
  }
}
