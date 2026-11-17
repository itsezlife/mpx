import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:http_bytes_cache/testing.dart';
import 'package:mpx/mpx.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';

const _quota = BytesQuota('previews', maxBytes: 1000);

void main() {
  PreviewStoreContract.run(() {
    final bytes = IndexedBytesCache(
      index: FakeBytesIndex(),
      blobs: FakeBytesBlobStore(),
      quotas: const [_quota],
    );
    addTearDown(bytes.close);
    final store = BytesCachePreviewStore(bytes);
    return PreviewStoreHarness(
      store: store,
      reopen: () async {
        await store.flush();
        return BytesCachePreviewStore(bytes);
      },
      quotaBytes: 1000,
    );
  });

  test(
    'previews are rows of the previews quota, under their own keys',
    () async {
      final bytes = MemoryBytesCache();
      addTearDown(bytes.close);
      final store = BytesCachePreviewStore(bytes);
      const key = MediaKey.remote('clip');
      final png = Uint8List.fromList([1, 2, 3]);

      store.write(key, png);
      expect(await bytes.read(BytesCachePreviewStore.cacheKeyOf(key)), isNull);
      await store.flush();

      expect(
        BytesCachePreviewStore.cacheKeyOf(key).value,
        'preview-${key.encoded}',
      );
      expect(await bytes.read(BytesCachePreviewStore.cacheKeyOf(key)), png);
    },
  );

  test('the memory tier keeps the most recent previews', () async {
    final bytes = MemoryBytesCache();
    addTearDown(bytes.close);
    final store = BytesCachePreviewStore(bytes, memoryEntries: 2);
    for (var i = 0; i < 3; i++) {
      store.write(MediaKey.remote('p$i'), Uint8List.fromList([i]));
    }

    expect(store.peek(const MediaKey.remote('p0')), isNull);
    expect(store.peek(const MediaKey.remote('p2')), [2]);
    expect(await store.read(const MediaKey.remote('p0')), [0]);
  });

  test('a long key is hashed into a short one', () {
    final key = MediaKey.remote('x' * 400);
    final cacheKey = BytesCachePreviewStore.cacheKeyOf(key);
    expect(cacheKey.value, startsWith('preview-hashed-'));
    expect(cacheKey.value.length, lessThanOrEqualTo(180));
  });
}
