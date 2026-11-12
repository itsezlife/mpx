import 'dart:typed_data';

import 'package:http_bytes_cache/src/bytes_cache.dart';
import 'package:http_bytes_cache/src/environment_specific/blob_store_routed_js.dart';
import 'package:http_bytes_cache/src/environment_specific/index_cache_js.dart';

/// Conditional-import hook: Cache API index + Cache/OPFS blobs by size.
///
/// [BytesCache.open] forwards here on web. [directory] exists only so the
/// signature matches the VM stub; it is ignored. Browser storage already owns
/// durability; there is no IsolateController on this path. Orphan reclaim is
/// wired into [IndexedBytesCache] so it shares the exclusive mutate
/// domain. Hard storage failures throw so [BytesCache.open] can degrade
/// to memory with a diagnostic.
///
/// On any failure after Cache/OPFS handles exist, this function closes those
/// partial resources before rethrowing so degrade / `throwOnOpenFailure` paths
/// cannot leak quota-holding handles.
Future<IBytesStore> $openBytesCache({
  String? directory,
  BytesRetention retention = BytesRetention.standard,
  DateTime Function()? clock,
}) async {
  BytesBlobStore$Routed$JS? blobs;
  BytesIndex$Cache$JS? index;
  BytesCache$JS? opened;
  try {
    blobs = await BytesBlobStore$Routed$JS.open();
    index = await BytesIndex$Cache$JS.open(onWipe: blobs.wipeAll);

    opened = BytesCache$JS(
      inner: IndexedBytesCache(
        index: index,
        blobs: blobs,
        retention: retention,
        clock: clock,
        reclaimOrphans: blobs.reclaimOrphans,
      ),
      index: index,
      blobs: blobs,
    );
    // Ownership transferred to [opened]; close goes through the wrapper.
    blobs = null;
    index = null;
    await opened.reclaimOrphans();
    return opened;
  } on Object {
    await opened?.close();
    await index?.close();
    await blobs?.close();
    rethrow;
  }
}

/// Closes Cache / OPFS handles around [IndexedBytesCache].
///
/// Reclaim stays on the inner brain’s exclusive gate. This wrapper does not
/// reclaim outside that domain.
final class BytesCache$JS implements IBytesStore {
  BytesCache$JS({
    required IndexedBytesCache inner,
    required BytesIndex$Cache$JS index,
    required BytesBlobStore$Routed$JS blobs,
  }) : _inner = inner,
       _index = index,
       _blobs = blobs;

  final IndexedBytesCache _inner;
  final BytesIndex$Cache$JS _index;
  final BytesBlobStore$Routed$JS _blobs;

  Future<void> reclaimOrphans() => _inner.reclaimOrphans();

  @override
  Future<Uint8List?> read(BytesCacheKey key) => _inner.read(key);

  @override
  Future<BytesRichHit?> readRich(BytesCacheKey key) => _inner.readRich(key);

  @override
  bool contains(BytesCacheKey key) => _inner.contains(key);

  @override
  Future<FileLease?> leaseFile(BytesCacheKey key) => _inner.leaseFile(key);

  @override
  Future<void> write(
    BytesCacheKey key,
    Uint8List bytes, {
    HttpCacheMeta? httpCacheMeta,
  }) => _inner.write(key, bytes, httpCacheMeta: httpCacheMeta);

  @override
  Future<void> evict(BytesCacheKey key) => _inner.evict(key);

  @override
  Future<BytesPruneReport> prune() => _inner.prune();

  @override
  Future<void> close() async {
    await _inner.close();
    await _index.close();
    await _blobs.close();
  }
}
