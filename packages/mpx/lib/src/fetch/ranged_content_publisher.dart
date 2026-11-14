import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx_core/mpx_core.dart';

/// Makes content readable natively while it downloads: what lets a decoder
/// that reads through a native reader (the software video decoder) start on
/// a clip before the whole file is there.
///
/// The [BytesCacheFetcher] asks it for missing content of [kinds] instead of
/// downloading the content first. It publishes the content's ranged resource
/// to the bytes cache's native reader and hands it out as a
/// [FetchedRanged]; the reader fetches what its reads miss, and releasing the
/// content withdraws the publication. `NativeRangedContentPublisher` in
/// `package:mpx/native.dart` is the VM implementation.
abstract interface class RangedContentPublisher {
  /// The kinds whose missing content goes out published, not downloaded.
  Set<MediaKind> get kinds;

  /// Publishes [request]'s ranged resource; releasing the content returned
  /// withdraws it.
  Future<FetchedRanged> publish(RangedRequest request);
}
