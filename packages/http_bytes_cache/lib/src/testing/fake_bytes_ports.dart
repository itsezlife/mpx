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

/// In-memory [IBytesBlobStore] keyed by [BytesCacheKey.value].
final class FakeBytesBlobStore implements IBytesBlobStore {
  /// Payloads by key value. Tests may inspect or seed it.
  final Map<String, Uint8List> payloads = {};

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

  /// Drops payloads whose key is not in [keep], like a platform reclaim.
  Future<void> reclaimOrphans(Set<String> keep) async {
    payloads.removeWhere((key, _) => !keep.contains(key));
  }
}
