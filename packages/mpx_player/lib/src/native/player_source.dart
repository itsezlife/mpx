import 'package:flutter/foundation.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx_core/mpx_core.dart';

/// Where a native player reads one media's bytes: a ranged resource of the
/// bytes cache, read natively through its reader of ranged resources.
@immutable
final class PlayerSource {
  /// Creates a source of [request]'s bytes in a [mimeType] container.
  const PlayerSource(this.request, {this.mimeType = 'video/mp4', this.codec});

  /// The ranged resource: its cache key and where its bytes are fetched.
  final RangedRequest request;

  /// The container's MIME type. Apple players open progressive MP4
  /// (`video/mp4`, `video/quicktime`) only; Android also opens WebM and
  /// Matroska.
  final String mimeType;

  /// The video codec as a MIME type (`video/hevc`, `video/av01`), when the
  /// host knows it. A source whose codec failed to decode on this device
  /// before is skipped for the next one.
  final String? codec;

  @override
  bool operator ==(Object other) =>
      other is PlayerSource &&
      other.request.cacheKey == request.cacheKey &&
      other.request.url == request.url &&
      other.mimeType == mimeType &&
      other.codec == codec;

  @override
  int get hashCode =>
      Object.hash(request.cacheKey, request.url, mimeType, codec);

  @override
  String toString() =>
      'PlayerSource(${request.cacheKey}, $mimeType, codec: $codec)';
}

/// The sources of [key] in the order the host prefers them (the best
/// quality first); empty when the key has no playable source. A native
/// player plays the first whose codec has not failed on this device, and
/// moves to the next when its decoder fails.
typedef PlayerSourcesOf = List<PlayerSource> Function(MediaKey key);
