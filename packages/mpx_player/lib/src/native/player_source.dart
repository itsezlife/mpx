import 'package:flutter/foundation.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx_core/mpx_core.dart';

/// How a native player reads a [PlayerSource].
enum PlayerSourceKind {
  /// One file read by byte ranges (MP4, WebM, Matroska).
  progressive,

  /// An HLS stream: playlists and segments, each its own resource.
  hls,
}

/// Where a native player reads one media's bytes: a ranged resource of the
/// bytes cache, read natively through its reader of ranged resources; or an
/// HLS stream whose parts go through the same cache.
@immutable
final class PlayerSource {
  /// Creates a source of [request]'s bytes in a [mimeType] container. A
  /// [mimeType] of HLS ([hlsMimeType], or `application/x-mpegURL`) makes it
  /// an HLS source, as [PlayerSource.hls] does.
  const PlayerSource(this.request, {this.mimeType = 'video/mp4', this.codec});

  /// Creates an HLS source: [request]'s URL is the playlist (a multivariant
  /// or a media playlist) and its cache key the stream's.
  ///
  /// Every part the player opens is keyed by its URL under the stream's key
  /// ([BytesCacheKey.within]) and fetched with [request]'s headers into its
  /// quota: playlists as whole resources revalidated by HTTP rules, segments
  /// as ranged resources read natively. Android plays it; Apple players open
  /// progressive files only and move to the next source.
  const PlayerSource.hls(this.request, {this.codec}) : mimeType = hlsMimeType;

  /// The MIME type of an HLS playlist.
  static const String hlsMimeType = 'application/vnd.apple.mpegurl';

  /// The resource: its cache key and where its bytes are fetched. For HLS,
  /// the playlist's URL and the stream's key.
  final RangedRequest request;

  /// The container's MIME type. Apple players open progressive MP4
  /// (`video/mp4`, `video/quicktime`) only; Android also opens WebM,
  /// Matroska and HLS.
  final String mimeType;

  /// The video codec as a MIME type (`video/hevc`, `video/av01`), when the
  /// host knows it. A source whose codec failed to decode on this device
  /// before is skipped for the next one.
  final String? codec;

  /// How a player reads this source, from [mimeType].
  PlayerSourceKind get kind => switch (mimeType.toLowerCase()) {
    'application/vnd.apple.mpegurl' ||
    'application/x-mpegurl' => PlayerSourceKind.hls,
    _ => PlayerSourceKind.progressive,
  };

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
