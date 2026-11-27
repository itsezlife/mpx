import 'package:http_bytes_cache/http_bytes_cache.dart' show IBytesStore;
import 'package:meta/meta.dart';
import 'package:mpx_core/mpx_core.dart';

/// What tracked downloads move their bytes through: the same pieces the
/// composition root builds its asset pipeline from.
///
/// A tracked download is the cache's own fetch of a content, made a job: it
/// resolves the key through [resolver], fetches the whole content through
/// [fetcher], which keeps the bytes in [store] and serves them by the
/// cache's priority queue inside the client's connection cap, and leases the
/// cached file from [store]. Parallel parts and ranged resume are the
/// fetcher's, so a download stopped and started again goes on from the bytes
/// the cache kept.
///
/// [store] must be the store [fetcher] writes to, and `Transfers.cacheKeyOf`
/// the mapping [fetcher] keys the content with.
@immutable
final class TransferDownloads {
  /// Downloads through [fetcher], described by [resolver], kept in [store].
  const TransferDownloads({
    required this.fetcher,
    required this.resolver,
    required this.store,
  });

  /// Fetches a content's bytes into [store].
  final ContentFetcher fetcher;

  /// Describes a key before its fetch.
  final MediaResolver resolver;

  /// The bytes store the content lands in.
  final IBytesStore store;
}
