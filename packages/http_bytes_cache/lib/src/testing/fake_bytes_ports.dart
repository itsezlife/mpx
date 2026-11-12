import 'dart:typed_data';

import 'package:http_bytes_cache/src/bytes_cache.dart';

/// In-memory [IBytesIndex]: a plain map, [commit] counts and does nothing.
///
/// Pair with [FakeBytesBlobStore] to build an [IndexedBytesCache] without
/// files or browser storage.
final class FakeBytesIndex implements IBytesIndex {
  /// Rows by key value. Tests may inspect or seed it.
  final Map<String, BytesRecord> records = {};

  /// How many times [commit] ran.
  int commitCount = 0;

  @override
  BytesRecord? peek(BytesCacheKey key) => records[key.value];

  @override
  Future<BytesRecord?> get(BytesCacheKey key) async => records[key.value];

  @override
  Future<void> put(BytesRecord record) async {
    records[record.key.value] = record;
  }

  @override
  Future<void> delete(BytesCacheKey key) async {
    records.remove(key.value);
  }

  @override
  Future<Iterable<BytesRecord>> values() async => records.values;

  @override
  Future<void> commit() async {
    commitCount++;
  }
}

/// In-memory [IBytesFileBlobStore] and [IBytesRangedBlobStore] keyed by
/// [BytesCacheKey.value].
///
/// [pathOf] names a path under [root] that is never created, so stores built
/// on it hand out [FileLease]s whose pinning tests can observe in [payloads].
final class FakeBytesBlobStore
    implements IBytesFileBlobStore, IBytesRangedBlobStore {
  /// Fake directory the [pathOf] paths sit under.
  static const String root = '/fake-bytes-blobs';

  /// Payloads by key value. Tests may inspect or seed it.
  final Map<String, Uint8List> payloads = {};

  @override
  String pathOf(BytesCacheKey key) => '$root/${key.value}';

  @override
  Future<Uint8List?> read(BytesCacheKey key, {int? knownByteLength}) async =>
      payloads[key.value];

  @override
  Future<void> write(BytesCacheKey key, Uint8List bytes) async {
    payloads[key.value] = bytes;
  }

  @override
  Future<void> delete(BytesCacheKey key) async {
    payloads.remove(key.value);
  }

  @override
  Future<void> writeAt(BytesCacheKey key, int offset, Uint8List bytes) async {
    final current = payloads[key.value] ?? Uint8List(0);
    final end = offset + bytes.length;
    final grown = current.length >= end
        ? Uint8List.fromList(current)
        : (Uint8List(end)..setAll(0, current));
    payloads[key.value] = grown..setAll(offset, bytes);
  }

  @override
  Future<Uint8List?> readAt(BytesCacheKey key, int offset, int length) async {
    final current = payloads[key.value];
    if (current == null || current.length < offset + length) return null;
    return Uint8List.sublistView(current, offset, offset + length);
  }

  @override
  Future<void> clear(BytesCacheKey key) async {
    payloads[key.value] = Uint8List(0);
  }

  /// Drops payloads whose key is not in [keep], like a platform reclaim.
  Future<void> reclaimOrphans(Set<String> keep) async {
    payloads.removeWhere((key, _) => !keep.contains(key));
  }
}
