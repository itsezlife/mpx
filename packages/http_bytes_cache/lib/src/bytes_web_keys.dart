import 'package:http_bytes_cache/src/bytes_cache.dart';

/// Synthetic origin for Cache API keys (RFC 2606 `.invalid`, never resolves).
///
/// Cache Storage requires absolute URLs. Real fetch URLs would collide with
/// network cache entries and invite accidental `add()` network hits. OPFS blob
/// files use [BytesCacheKey.value] as the filename under
/// [opfsBlobsDirectoryName] instead (no URL scheme there).
///
/// The names keep their `image_bytes` spelling from before the package was
/// renamed: changing them would orphan every store already on disk.
abstract final class BytesWebKeys {
  /// Named Cache for the versioned index JSON document (metadata only).
  static const String indexCacheName = 'image_bytes_index_v1';

  /// Named Cache for small payload Responses (one entry per [BytesCacheKey]).
  ///
  /// Bodies at or above the web OPFS threshold live under
  /// [opfsBlobsDirectoryName], not here.
  static const String blobsCacheName = 'image_bytes_blobs_v1';

  /// OPFS subdirectory under `navigator.storage.getDirectory()` for large
  /// payloads (one file per [BytesCacheKey.value]).
  static const String opfsBlobsDirectoryName = 'image_bytes_blobs_v1';

  /// Single document URL inside [indexCacheName].
  static const String indexDocumentUrl =
      'https://image-bytes.invalid/v1/index.json';

  /// Payload URL for [key] inside [blobsCacheName].
  static String blobUrl(BytesCacheKey key) =>
      'https://image-bytes.invalid/v1/blob/${Uri.encodeComponent(key.value)}';

  /// Inverse of [blobUrl]. Returns `null` when [url] is not a blob entry.
  static String? keyValueFromBlobUrl(String url) {
    final uri = Uri.tryParse(url);
    return switch (uri) {
      null => null,
      final parsed when parsed.host != 'image-bytes.invalid' => null,
      final parsed => switch (parsed.pathSegments) {
        [final v, final kind, final encoded] when v == 'v1' && kind == 'blob' =>
          Uri.decodeComponent(encoded),
        _ => null,
      },
    };
  }
}
