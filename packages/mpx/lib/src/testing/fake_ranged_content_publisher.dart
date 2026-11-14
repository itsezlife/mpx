import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx/src/fetch/ranged_content_publisher.dart';
import 'package:mpx_core/mpx_core.dart';

/// A [RangedContentPublisher] with no native reader: it records what it
/// publishes and counts what is released.
final class FakeRangedContentPublisher implements RangedContentPublisher {
  /// Creates a publisher of [kinds] whose content names [readerApi].
  FakeRangedContentPublisher({
    this.kinds = const {MediaKind.video},
    this.readerApi = 0x1000,
  });

  @override
  final Set<MediaKind> kinds;

  /// The reader table address the content names.
  final int readerApi;

  /// What was published, oldest first.
  final List<RangedRequest> published = [];

  /// How many publications were released.
  int released = 0;

  @override
  Future<FetchedRanged> publish(RangedRequest request) async {
    published.add(request);
    return FetchedRanged(
      readerApi: readerApi,
      key: request.cacheKey.value,
      onRelease: () => released++,
    );
  }
}
