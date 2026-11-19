import 'package:flutter/foundation.dart';
import 'package:mpx_capture/src/prepare/preparation_policy.dart';
import 'package:mpx_core/mpx_core.dart';

/// A JPEG a [PreparationCodec] wrote: into a file, or into [bytes].
@immutable
final class EncodedStill {
  /// Describes an encoded still.
  const EncodedStill({
    required this.dimensions,
    required this.byteSize,
    this.bytes,
  });

  /// Its pixel size, upright.
  final MediaDimensions dimensions;

  /// Its size in bytes.
  final int byteSize;

  /// The JPEG, when it was encoded into memory; null when it went to a file.
  final Uint8List? bytes;

  @override
  String toString() => 'EncodedStill($dimensions, $byteSize B)';
}

/// The platform's still and poster work that media preparation needs: read
/// a still's facts, encode a JPEG from it, and draw a video's first frame.
///
/// Every call reads and writes off the UI isolate. Orientation stored in the
/// file is applied, so sizes are as displayed and outputs are upright.
/// Implementations: `PlatformPreparationCodec` (a downsampled decode on
/// Android, ImageIO on iOS and macOS) and the fake in `testing.dart`; both
/// meet `PreparationCodecContract`.
abstract interface class PreparationCodec {
  /// Reads the still at [path]: size as displayed, file size, MIME type,
  /// and whether it has more than one frame.
  ///
  /// Throws `CaptureFailed` when it is not a still the platform reads.
  Future<StillSource> probeStill(String path);

  /// Encodes the still at [path] as a JPEG whose long side is at most
  /// [maxSide] (never scaled up) at [quality] (1 to 100), [progressive] or
  /// baseline: into [outputPath] (replaced) when set, else into memory.
  ///
  /// Throws `CaptureFailed` when it cannot read or write.
  Future<EncodedStill> encodeStill(
    String path, {
    required int maxSide,
    required int quality,
    bool progressive = false,
    String? outputPath,
  });

  /// Encodes the first frame of the video at [path], upright, fitted into
  /// [spec]'s square at its quality, into memory.
  ///
  /// Throws `CaptureFailed` when it is not a video the platform reads.
  Future<EncodedStill> videoThumbnail(String path, ThumbnailSpec spec);
}
