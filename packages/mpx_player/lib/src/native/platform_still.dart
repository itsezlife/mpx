import 'package:flutter/foundation.dart';
import 'package:mpx_core/mpx_core.dart';

/// Where a platform still extractor reads a video: a ranged resource of the
/// bytes cache's native reader, or a file of the host's disk tier. Never
/// bytes in memory: no video is loaded whole for a still.
@immutable
sealed class PlatformStillSource {
  /// The ranged resource [key] of the native reader whose function table is
  /// at [readerApi]; reads block while its bytes download.
  const factory PlatformStillSource.ranged({
    required int readerApi,
    required String key,
  }) = PlatformStillSource$Ranged;

  /// The file at [path].
  const factory PlatformStillSource.file(String path) =
      PlatformStillSource$File;

  const PlatformStillSource._();
}

/// A [PlatformStillSource] read through the native reader.
final class PlatformStillSource$Ranged extends PlatformStillSource {
  /// Creates the source of resource [key] at the reader [readerApi].
  const PlatformStillSource$Ranged({required this.readerApi, required this.key})
    : super._();

  /// Address of the native reader's function table.
  final int readerApi;

  /// The resource the reader opens.
  final String key;

  @override
  bool operator ==(Object other) =>
      other is PlatformStillSource$Ranged &&
      other.readerApi == readerApi &&
      other.key == key;

  @override
  int get hashCode => Object.hash(readerApi, key);

  @override
  String toString() => 'PlatformStillSource.ranged($key)';
}

/// A [PlatformStillSource] in a file.
final class PlatformStillSource$File extends PlatformStillSource {
  /// Creates the source of the file at [path].
  const PlatformStillSource$File(this.path) : super._();

  /// Where the video is.
  final String path;

  @override
  bool operator ==(Object other) =>
      other is PlatformStillSource$File && other.path == path;

  @override
  int get hashCode => path.hashCode;

  @override
  String toString() => 'PlatformStillSource.file($path)';
}

/// What a [PlatformStillBackend] is asked to draw: the first frame of
/// [source] within [maxWidth] x [maxHeight] pixels, its aspect kept and its
/// rotation applied, never scaled up.
@immutable
final class PlatformStillRequest {
  /// Creates a request.
  const PlatformStillRequest({
    required this.source,
    required this.maxWidth,
    required this.maxHeight,
  });

  /// Where the video is read.
  final PlatformStillSource source;

  /// The widest the still may be.
  final int maxWidth;

  /// The tallest the still may be.
  final int maxHeight;
}

/// A still a [PlatformStillBackend] drew: [width] x [height] pixels as
/// premultiplied RGBA, four bytes each, rows packed.
@immutable
final class PlatformStill {
  /// Creates a still of [rgba] pixels.
  const PlatformStill({
    required this.width,
    required this.height,
    required this.rgba,
  });

  /// Its width in pixels.
  final int width;

  /// Its height in pixels.
  final int height;

  /// Its pixels.
  final Uint8List rgba;
}

/// The platform's still extractor, as `PlatformStillDecoder` uses it: the
/// first frame of a video drawn by the platform's own decoders (hardware
/// ones included), for codecs the software decoder was built without.
///
/// The native backend reads through the bytes cache's native reader on a
/// thread of its own. A later platform (an FFmpeg still on Linux) is
/// another implementation of this seam.
abstract interface class PlatformStillBackend {
  /// Draws the first frame of [request]'s video; null when the platform
  /// cannot either. When [cancellation] is cancelled the backend wakes the
  /// reads it blocks in, and its answer no longer matters; the future still
  /// completes once the platform lets go of the source.
  Future<PlatformStill?> extract(
    PlatformStillRequest request,
    CancellationToken cancellation,
  );
}
