import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx_core/mpx_core.dart';

/// Makes content readable natively while it downloads: what lets a decoder
/// that reads through a native reader (the software video decoder) start on
/// a clip before the whole file is there.
///
/// The [BytesCacheFetcher] asks it for missing content of [kinds] instead of
/// downloading the content first. It publishes the content's ranged resource
/// to the bytes cache's native reader, fetches what an open needs (the
/// index and a first stretch), and hands it out as a [FetchedRanged]; from
/// then on the decoder's reads ask for the bytes ahead of them, so only
/// what plays is fetched, and a clip that stops playing (off screen) stops
/// fetching, keeping what it has. Releasing the content withdraws the
/// publication. `NativeRangedContentPublisher` in `package:mpx/native.dart`
/// is the VM implementation.
///
/// For a decoder that never waits on its source: one whose reads of
/// missing bytes answer at once (the software video decoder stalls the
/// clip and tries again on [FetchedRanged.landed]), so no shared thread or
/// slot is held while the network catches up.
abstract interface class RangedContentPublisher {
  /// The kinds whose missing content goes out published, not downloaded.
  Set<MediaKind> get kinds;

  /// Publishes [request]'s ranged resource and completes once its index
  /// and first stretch are there, fetched at [priority]; releasing the
  /// content returned withdraws it. [cancelToken] stops the fetch.
  Future<FetchedRanged> publish(
    RangedRequest request, {
    PriorityToken? priority,
    CancelToken? cancelToken,
  });
}
