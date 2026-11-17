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
    this.firstStretchBytes = defaultFirstStretchBytes,
  });

  /// The head handed over with a clip by default: about two seconds of a
  /// 1080p clip.
  static const int defaultFirstStretchBytes = 2 * 1024 * 1024;

  /// Bytes from the start that are fetched before the content is handed
  /// out, with the index (`moov`) of an MP4 wherever it is: what an open
  /// and the first frames read, so the decoder starts without stalling.
  final int firstStretchBytes;

  /// The process's native reader.
  final NativeRangedReaders readers;

  @override
  final Set<MediaKind> kinds;

  @override
  Future<FetchedRanged> publish(
    RangedRequest request, {
    PriorityToken? priority,
    CancelToken? cancelToken,
    FetchProgress? onProgress,
    bool whole = false,
  }) async {
    final publication = await readers.publish(request);
    final resource = publication.resource;
    // The bytes as they land, the head's and the reads' alike.
    final reports = onProgress == null
        ? null
        : resource.events.listen((event) {
            if (event is RangeLanded) {
              onProgress(resource.ranges.coveredBytes, resource.totalLength);
            }
          });
    try {
      // The head, then the index wherever it is (the tail of a file whose
      // moov follows its media data), never the middle.
      await resource.fastStart(
        headBytes: firstStretchBytes,
        priority: priority,
        cancelToken: cancelToken,
      );
    } on Object {
      await reports?.cancel();
      await publication.close();
      rethrow;
    }
    // A user's download: the rest behind the reads, until released.
    final rest = CancelToken();
    if (whole) {
      unawaited(
        resource
            .ensure(const ByteRange(0), priority: priority, cancelToken: rest)
            .then(
              (_) {},
              // A rest that fails or is stopped leaves the content partial,
              // as a stream is: the reads ask for what they miss, and the
              // next download for the rest.
              onError: (Object _) {},
            ),
      );
    }
    return FetchedRanged(
      readerApi: NativeRangedReaders.apiAddress,
      key: request.cacheKey.value,
      landed: resource.events.where((event) => event is RangeLanded),
      // Off screen: the rest of the chunk fetched ahead of its reads stops,
      // what landed stays, and its next reads ask from there.
      onPause: publication.stopHints,
      onRelease: () {
        rest.cancel();
        unawaited(reports?.cancel());
        unawaited(publication.close());
      },
    );
  }
}
