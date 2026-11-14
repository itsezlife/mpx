import 'dart:async';

import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:http_bytes_cache/native_reader.dart';
import 'package:mpx/src/fetch/ranged_content_publisher.dart';
import 'package:mpx_core/mpx_core.dart';

/// A [RangedContentPublisher] over the bytes cache's native reader: content
/// goes out as the address of the reader's function table and the cache key
/// it serves, and is withdrawn when released.
final class NativeRangedContentPublisher implements RangedContentPublisher {
  /// Publishes through [readers] the content of [kinds] (video by default:
  /// the software video decoder reads through the native reader).
  NativeRangedContentPublisher(
    this.readers, {
    this.kinds = const {MediaKind.video},
  });

  /// The process's native reader.
  final NativeRangedReaders readers;

  @override
  final Set<MediaKind> kinds;

  @override
  Future<FetchedRanged> publish(RangedRequest request) async {
    final publication = await readers.publish(request);
    return FetchedRanged(
      readerApi: NativeRangedReaders.apiAddress,
      key: request.cacheKey.value,
      onRelease: () => unawaited(publication.close()),
    );
  }
}
