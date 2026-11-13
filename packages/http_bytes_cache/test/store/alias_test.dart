import 'dart:io';
import 'dart:typed_data';

import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:http_bytes_cache/testing.dart';
import 'package:test/test.dart';

void main() {
  const local = BytesCacheKey('local-uuid');
  const server = BytesCacheKey('server-42');
  final captured = Uint8List.fromList([7, 7, 7]);

  group('Alias and release', () {
    late DateTime now;
    late FakeBytesIndex index;
    late FakeBytesBlobStore blobs;
    late IndexedBytesCache store;

    setUp(() async {
      now = DateTime.utc(2026, 1, 1);
      index = FakeBytesIndex();
      blobs = FakeBytesBlobStore();
      store = IndexedBytesCache(
        index: index,
        blobs: blobs,
        clock: () => now = now.add(const Duration(seconds: 1)),
        retention: const BytesRetention.maxBytes(10),
        quotas: const [],
        reclaimOrphans: blobs.reclaimOrphans,
      );
      addTearDown(store.close);
      await store.write(local, captured);
    });

    test('the server key resolves to the local bytes without a copy', () async {
      expect(await store.alias(local, server), isTrue);

      expect(await store.read(server), captured);
      expect(store.contains(server), isTrue);
      expect(blobs.payloads.keys, [local.value]);
    });

    test('release while aliased drops only the local key', () async {
      await store.alias(local, server);
      await store.release(local);

      expect(await store.read(local), isNull);
      expect(store.contains(local), isFalse);
      expect(await store.read(server), captured);

      await store.evict(server);
      expect(blobs.payloads, isEmpty);
    });

    test('release without an alias drops the bytes', () async {
      await store.release(local);
      expect(await store.read(local), isNull);
      expect(blobs.payloads, isEmpty);
    });

    test('an alias onto a key with bytes replaces them', () async {
      await store.write(server, Uint8List.fromList([1]));
      await store.alias(local, server);

      expect(await store.read(server), captured);
      expect(blobs.payloads.keys, [local.value]);
    });

    test('an alias of a key that holds nothing is refused', () async {
      await store.write(server, Uint8List.fromList([1]));
      expect(
        await store.alias(const BytesCacheKey('missing'), server),
        isFalse,
      );
      expect(await store.read(server), [1]);
    });

    test('a chain of aliases points at the one payload', () async {
      const mirror = BytesCacheKey('mirror');
      await store.alias(local, server);
      await store.alias(server, mirror);
      await store.release(local);
      await store.evict(server);

      expect(await store.read(mirror), captured);
      expect(blobs.payloads.keys, [local.value]);
    });

    test('a shared payload counts once against the budget', () async {
      await store.alias(local, server);
      await store.write(const BytesCacheKey('other'), Uint8List(5));

      expect(index.records.keys, containsAll([local.value, server.value]));
    });

    test('a lease on the server key names the local payload file', () async {
      await store.alias(local, server);
      final lease = (await store.leaseFile(server))!;
      expect(lease.path, blobs.pathOf(local));

      await store.release(local);
      await store.evict(server);
      expect(blobs.payloads.keys, [local.value]);
      await lease.release();
      expect(blobs.payloads, isEmpty);
    });

    test('the server row keeps the length of the bytes it reads', () async {
      await store.alias(local, server);
      await store.write(local, Uint8List.fromList([1, 2, 3, 4, 5]));

      expect(await store.read(server), captured);
      expect((await index.get(server))!.byteLength, captured.length);
      expect((await index.get(local))!.byteLength, 5);
    });

    test('a write after release leaves the server bytes alone', () async {
      await store.alias(local, server);
      await store.release(local);
      await store.write(local, Uint8List.fromList([1]));

      expect(await store.read(server), captured);
      expect(await store.read(local), [1]);
    });

    test(
      'a key aliased onto a payload a third key reads is not reused',
      () async {
        const mirror = BytesCacheKey('mirror');
        await store.write(server, Uint8List.fromList([5, 5]));
        await store.alias(server, mirror);
        await store.alias(local, server);
        await store.write(local, Uint8List.fromList([1]));

        // The server key cannot take the bytes over (its own payload is the
        // mirror's), so it misses rather than serve wrong bytes.
        expect(await store.read(mirror), [5, 5]);
        expect(await store.read(server), isNull);
        expect(await store.read(local), [1]);
      },
    );

    test('ranges of another representation leave the server bytes', () async {
      await store.alias(local, server);
      await store.writeRange(
        local,
        0,
        Uint8List.fromList([1, 2]),
        validator: const HttpCacheMeta(etag: '"v2"'),
        totalLength: 4,
      );

      expect(await store.read(server), captured);
    });

    test('writing the server key gives it its own payload', () async {
      await store.alias(local, server);
      await store.write(server, Uint8List.fromList([9]));

      expect(await store.read(server), [9]);
      expect(await store.read(local), captured);
    });
  });

  group('Alias on the VM store', () {
    test('survives a reopen after the local key is released', () async {
      final dir = Directory.systemTemp.createTempSync('http_bytes_alias_');
      addTearDown(() => dir.deleteSync(recursive: true));
      Future<IBytesStore> open() => BytesCache.open(
        directory: dir.path,
        throwOnOpenFailure: true,
      );

      final first = await open();
      await first.write(local, captured);
      await first.alias(local, server);
      await first.release(local);
      await first.close();

      final second = await open();
      addTearDown(second.close);
      expect(await second.read(server), captured);
      expect(await second.read(local), isNull);
    });
  });
}
