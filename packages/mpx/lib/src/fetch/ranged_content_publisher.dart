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
///
/// Opt-in, and only for a decoder that can afford to wait: a read of bytes
/// the network has not brought blocks the thread that decodes, and the
/// pipeline's decode slot stays taken meanwhile. On a pool of worker
/// isolates (`IsolateVideoEngine`) every clip sharing the worker waits with
/// it, so a few clips still downloading from a far origin hold back clips
/// that are already held. Without a publisher the fetcher downloads the
/// content whole (on the client's transfer worker) before it decodes.
abstract interface class RangedContentPublisher {
  /// The kinds whose missing content goes out published, not downloaded.
  Set<MediaKind> get kinds;

  /// Publishes [request]'s ranged resource; releasing the content returned
  /// withdraws it.
  Future<FetchedRanged> publish(RangedRequest request);
}
