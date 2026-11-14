import 'dart:typed_data';

import 'package:http_bytes_cache/src/bytes_cache.dart';
import 'package:http_bytes_cache/src/environment_specific/blob_store_file_vm.dart';
import 'package:http_bytes_cache/src/environment_specific/index_file_vm.dart';
import 'package:http_bytes_cache/src/http/byte_range.dart';

/// VM hook behind [BytesCache.open].
///
/// Wires [BytesIndex$File$VM] + [BytesBlobStore$File$VM] into
/// [IndexedBytesCache] with orphan reclaim inside the brain’s exclusive
/// domain, reclaims once at open, and closes the isolate worker with the cache.
/// Call [BytesCache.open] from app code, not this symbol. [directory] is
/// required. Degraded open (Memory + diagnostic) is handled by
/// [BytesCache.open], not here.
///
/// On any failure after a blob store (and its isolate worker) exists, this
/// function closes those partial resources before rethrowing so
/// [BytesCache.open] degrade / `throwOnOpenFailure` paths cannot leak
/// workers. Missing [directory] still throws [ArgumentError] before any spawn.
Future<IBytesStore> $openBytesCache({
  String? directory,
  BytesRetention retention = BytesRetention.standard,
  Iterable<BytesQuota> quotas = BytesQuota.standard,
  DateTime Function()? clock,
}) async {
  final root = switch (directory) {
    final d? when d.isNotEmpty => d,
    _ => throw ArgumentError.value(directory, 'directory', 'required on VM'),
  };

  BytesBlobStore$File$VM? blobs;
  BytesCache$VM? opened;
  try {
    blobs = BytesBlobStore$File$VM(directory: root);
    await blobs.ensureDirectory();
    final index = await BytesIndex$File$VM.open(
      directory: root,
      io: blobs,
      onWipe: blobs.wipeAll,
    );

    opened = BytesCache$VM(
      inner: IndexedBytesCache(
        index: index,
        blobs: blobs,
        retention: retention,
        quotas: quotas,
        clock: clock,
        reclaimOrphans: blobs.reclaimOrphans,
      ),
      blobs: blobs,
    );
    // Ownership of [blobs] transferred to [opened]; close goes through the wrapper.
    blobs = null;
    await opened.reclaimOrphans();
    return opened;
  } on Object {
    await opened?.close();
    await blobs?.close();
    rethrow;
  }
}

/// Closes the isolate worker around [IndexedBytesCache].
///
/// Orphan reclaim on open/prune stays on the inner brain’s exclusive
/// gate. This wrapper does not reclaim outside that domain.
final class BytesCache$VM implements IRangedBytesStore {
  BytesCache$VM({
    required IndexedBytesCache inner,
    required BytesBlobStore$File$VM blobs,
  }) : _inner = inner,
       _blobs = blobs;

  final IndexedBytesCache _inner;
  final BytesBlobStore$File$VM _blobs;

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
  RegisteredQuota registerQuota(
    BytesQuota quota, {
    required QuotaEvictor onEvict,
  }) => _inner.registerQuota(quota, onEvict: onEvict);

  @override
  Future<bool> alias(BytesCacheKey local, BytesCacheKey server) =>
      _inner.alias(local, server);

  @override
  Future<void> release(BytesCacheKey local) => _inner.release(local);

  @override
  Future<void> write(
    BytesCacheKey key,
    Uint8List bytes, {
    HttpCacheMeta? httpCacheMeta,
    BytesQuota? quota,
  }) => _inner.write(key, bytes, httpCacheMeta: httpCacheMeta, quota: quota);

  @override
  Future<void> evict(BytesCacheKey key) => _inner.evict(key);

  @override
  bool get supportsRanges => _inner.supportsRanges;

  @override
  RangedState? rangesOf(BytesCacheKey key) => _inner.rangesOf(key);

  @override
  Future<FileLease> openRanged(BytesCacheKey key, {BytesQuota? quota}) =>
      _inner.openRanged(key, quota: quota);

  @override
  Future<RangedState> writeRange(
    BytesCacheKey key,
    int offset,
    Uint8List bytes, {
    HttpCacheMeta? validator,
    int? totalLength,
    BytesQuota? quota,
  }) => _inner.writeRange(
    key,
    offset,
    bytes,
    validator: validator,
    totalLength: totalLength,
    quota: quota,
  );

  @override
  Future<RangedState> recordRange(
    BytesCacheKey key,
    int offset,
    int length, {
    HttpCacheMeta? validator,
    int? totalLength,
    BytesQuota? quota,
  }) => _inner.recordRange(
    key,
    offset,
    length,
    validator: validator,
    totalLength: totalLength,
    quota: quota,
  );

  @override
  Future<RangedState> resetRanges(
    BytesCacheKey key, {
    HttpCacheMeta? validator,
    int? totalLength,
    BytesQuota? quota,
  }) => _inner.resetRanges(
    key,
    validator: validator,
    totalLength: totalLength,
    quota: quota,
  );

  @override
  Future<Uint8List?> readRange(BytesCacheKey key, ByteRange range) =>
      _inner.readRange(key, range);

  @override
  Future<BytesPruneReport> prune() => _inner.prune();

  @override
  Future<void> close() async {
    await _inner.close();
    await _blobs.close();
  }
}
