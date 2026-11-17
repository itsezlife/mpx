import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:http_bytes_cache/src/bytes_index_document.dart';
import 'package:http_bytes_cache/testing.dart';
import 'package:test/test.dart';

const _images = BytesQuota('images', maxBytes: 10);
const _video = BytesQuota('video', maxBytes: 20);

void main() {
  late DateTime now;
  late FakeBytesIndex index;
  late FakeBytesBlobStore blobs;

  IndexedBytesCache open({
    BytesRetention retention = const BytesRetention.unlimited(),
    List<BytesQuota> quotas = const [_images, _video],
  }) {
    final store = IndexedBytesCache(
      index: index,
      blobs: blobs,
      clock: () => now,
      retention: retention,
      quotas: quotas,
    );
    addTearDown(store.close);
    return store;
  }

  Future<void> put(
    IBytesStore store,
    String key,
    int length, [
    BytesQuota? quota,
  ]) async {
    now = now.add(const Duration(minutes: 1));
    await store.write(
      BytesCacheKey(key),
      Uint8List(length)..fillRange(0, length, 1),
      quota: quota,
    );
  }

  setUp(() {
    now = DateTime.utc(2026, 1, 1);
    index = FakeBytesIndex();
    blobs = FakeBytesBlobStore();
  });

  group('Named quotas', () {
    test('a full quota evicts only within itself', () async {
      final store = open(
        quotas: const [_images, BytesQuota('video', maxBytes: 10)],
      );
      await put(store, 'avatar-1', 4, _images);
      await put(store, 'avatar-2', 4, _images);
      await put(store, 'clip-1', 6, const BytesQuota('video', maxBytes: 10));
      await put(store, 'clip-2', 6, const BytesQuota('video', maxBytes: 10));

      expect(
        index.records.keys,
        unorderedEquals(['avatar-1', 'avatar-2', 'clip-2']),
      );
    });

    test('under the total budget, the quota furthest over its share gives '
        'back', () async {
      final store = open(retention: const BytesRetention.maxBytes(12));
      await put(store, 'avatar-1', 4, _images);
      await put(store, 'clip-1', 4, _video);
      await put(store, 'avatar-2', 4, _images);
      await put(store, 'clip-2', 4, _video);

      // images use 8 of 10, video 8 of 20: images give back their oldest.
      expect(
        index.records.keys,
        unorderedEquals(['avatar-2', 'clip-1', 'clip-2']),
      );
    });

    test(
      'a write without a quota keeps the row quota, else the default',
      () async {
        final store = open();
        await put(store, 'clip', 2, _video);
        await put(store, 'clip', 3);
        await put(store, 'plain', 1);

        expect(index.records['clip']!.quota, 'video');
        expect(index.records['plain']!.quota, BytesQuota.images.name);
      },
    );

    test('a leased file survives its quota filling up', () async {
      final store = open();
      await put(store, 'avatar-1', 6, _images);
      final lease = (await store.leaseFile(const BytesCacheKey('avatar-1')))!;
      await put(store, 'avatar-2', 6, _images);

      expect(blobs.payloads.keys, contains('avatar-1'));
      await lease.release();
    });

    test('the resolver writes into the request quota', () async {
      final store = open();
      final client = HttpBytesClient(
        client: MockClient((_) async => http.Response.bytes([1, 2], 200)),
        middlewares: const [],
      );
      addTearDown(client.close);
      await BytesResolver(cache: store, client: client).resolve(
        const BytesRequest(
          url: 'https://cdn.example.com/c.mp4',
          cacheKey: BytesCacheKey('c'),
          quota: _video,
        ),
      );
      await pumpEventQueue();
      expect(index.records['c']!.quota, 'video');
    });

    test('the index document keeps the quota and reads old rows as images', () {
      const codec = BytesIndexDocumentCodec();
      final record = BytesRecord(
        key: const BytesCacheKey('k'),
        writtenAt: DateTime.utc(2026),
        accessedAt: DateTime.utc(2026),
        byteLength: 3,
        quota: const BytesQuotaName('video'),
      );
      final decoded = codec.decode(codec.encode({'k': record}));
      expect(decoded['k']!.quota, 'video');

      final old = codec.decode(
        '{"v":1,"e":{"k":{"w":0,"a":0,"n":1}}}'.codeUnits,
      );
      expect(old['k']!.quota, BytesQuota.images.name);
    });
  });

  group('Last-use expiry', () {
    const key = BytesCacheKey('gif');
    const retention = BytesRetention.maxAge(Duration(days: 10));

    test('a row used within the horizon outlives its write age', () async {
      final store = open(retention: retention);
      await store.write(key, Uint8List.fromList([1]));
      now = now.add(const Duration(days: 9));
      expect(await store.read(key), isNotNull);

      now = now.add(const Duration(days: 6));
      expect(store.contains(key), isTrue);
      expect(await store.read(key), isNotNull);
    });

    test('a row unused past the horizon expires', () async {
      final store = open(retention: retention);
      await store.write(key, Uint8List.fromList([1]));
      now = now.add(const Duration(days: 9));
      await store.read(key);
      now = now.add(const Duration(days: 11));

      expect(store.contains(key), isFalse);
      expect(await store.read(key), isNull);
    });

    test('prune drops by last use', () async {
      final store = open(retention: retention);
      await store.write(key, Uint8List.fromList([1]));
      await store.write(const BytesCacheKey('stale'), Uint8List.fromList([2]));
      now = now.add(const Duration(days: 8));
      await store.read(key);
      now = now.add(const Duration(days: 8));

      final report = await store.prune();
      expect(report.evictedKeys, [const BytesCacheKey('stale')]);
      expect(index.records.keys, ['gif']);
    });

    test('the memory store expires by last use too', () async {
      final memory = MemoryBytesCache(clock: () => now, retention: retention);
      await memory.write(key, Uint8List.fromList([1]));
      now = now.add(const Duration(days: 9));
      await memory.read(key);
      now = now.add(const Duration(days: 9));
      expect(await memory.read(key), isNotNull);
    });

    test('the standard quotas hold 4 MiB of previews', () {
      expect(BytesQuota.previews.name, const BytesQuotaName('previews'));
      expect(BytesQuota.previews.maxBytes, 4 * 1024 * 1024);
      expect(BytesQuota.standard, contains(BytesQuota.previews));
    });

    test('the standard horizon is one month', () {
      expect(BytesRetention.standard.limits.maxAge, const Duration(days: 30));
    });
  });
}
