import 'dart:io';

import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:http_bytes_cache/testing.dart';
import 'package:test/test.dart';

void main() {
  runBytesStoreContract(
    'MemoryBytesCache',
    ({required clock, required retention}) async =>
        MemoryBytesCache(clock: clock, retention: retention),
  );

  runBytesStoreContract('IndexedBytesCache', ({
    required clock,
    required retention,
  }) async {
    final blobs = FakeBytesBlobStore();
    return IndexedBytesCache(
      index: FakeBytesIndex(),
      blobs: blobs,
      clock: clock,
      retention: retention,
      reclaimOrphans: blobs.reclaimOrphans,
    );
  });

  runBytesStoreContract('Opened VM store', ({
    required clock,
    required retention,
  }) async {
    final dir = Directory.systemTemp.createTempSync('http_bytes_store_');
    addTearDown(() => dir.deleteSync(recursive: true));
    return BytesCache.open(
      directory: dir.path,
      clock: clock,
      retention: retention,
      throwOnOpenFailure: true,
    );
  });

  runBytesStoreContract('MiddlewareBytesCache over memory', ({
    required clock,
    required retention,
  }) async {
    return MiddlewareBytesCache(
      inner: MemoryBytesCache(clock: clock, retention: retention),
    );
  });
}
