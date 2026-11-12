import 'dart:io';
import 'dart:typed_data';

import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:http_bytes_cache/testing.dart';
import 'package:test/test.dart';

import '../support/range_server.dart';

/// The ranged half of the store: sparse payloads with a range set, on the
/// fake ports and on the VM store.
void main() {
  const video = BytesCacheKey('video');
  const v1 = HttpCacheMeta(etag: '"v1"');
  final body = patternBytes(4000);

  Uint8List slice(int start, int end) => body.sublist(start, end);

  runRangedBytesStoreContract(
    'IndexedBytesCache over fake ports',
    ({required clock, required retention}) async => IndexedBytesCache(
      index: FakeBytesIndex(),
      blobs: FakeBytesBlobStore(),
      retention: retention,
      clock: clock,
      quotas: const [BytesQuota('video_ranges')],
    ),
  );

  runRangedBytesStoreContract('Opened VM store', ({
    required clock,
    required retention,
  }) async {
    final dir = await Directory.systemTemp.createTemp('ranged_store_');
    addTearDown(() => dir.delete(recursive: true));
    final store = await BytesCache.open(
      directory: dir.path,
      retention: retention,
      quotas: const [BytesQuota('video_ranges')],
      clock: clock,
      throwOnOpenFailure: true,
    );
    return store as IRangedBytesStore;
  });

  group('VM store durability', () {
    test('ranges and the sparse file survive a reopen', () async {
      final dir = await Directory.systemTemp.createTemp('ranged_reopen_');
      addTearDown(() => dir.delete(recursive: true));
      Future<IRangedBytesStore> open() async =>
          await BytesCache.open(directory: dir.path, throwOnOpenFailure: true)
              as IRangedBytesStore;

      final first = await open();
      await first.writeRange(
        video,
        1000,
        slice(1000, 1100),
        validator: v1,
        totalLength: 4000,
      );
      await first.close();

      final second = await open();
      addTearDown(second.close);
      final state = second.rangesOf(video)!;
      expect(state.ranges.spans, [(1000, 1100)]);
      expect(state.totalLength, 4000);
      expect(state.validator?.etag, '"v1"');
      expect(
        await second.readRange(video, const ByteRange(1000, 1100)),
        slice(1000, 1100),
      );
    });

    test('a store without a ranged payload port answers unsupported', () {
      final store = IndexedBytesCache(
        index: FakeBytesIndex(),
        blobs: _WholeOnlyBlobs(),
      );
      addTearDown(store.close);

      expect(store.supportsRanges, isFalse);
      expect(() => store.openRanged(video), throwsUnsupportedError);
    });
  });
}

final class _WholeOnlyBlobs implements IBytesBlobStore {
  @override
  Future<void> delete(BytesCacheKey key) async {}

  @override
  Future<Uint8List?> read(BytesCacheKey key, {int? knownByteLength}) async =>
      null;

  @override
  Future<void> write(BytesCacheKey key, Uint8List bytes) async {}
}
