import 'dart:io';
import 'dart:typed_data';

import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:http_bytes_cache/testing.dart';
import 'package:test/test.dart';

void main() {
  group('File lease', () {
    late DateTime now;
    late FakeBytesBlobStore blobs;
    late IndexedBytesCache store;

    const a = BytesCacheKey('a');
    const b = BytesCacheKey('b');
    const c = BytesCacheKey('c');
    const d = BytesCacheKey('d');

    Future<void> put(BytesCacheKey key) async {
      now = now.add(const Duration(minutes: 1));
      await store.write(key, Uint8List.fromList([key.value.codeUnitAt(0)]));
    }

    setUp(() {
      now = DateTime.utc(2026, 1, 1);
      blobs = FakeBytesBlobStore();
      store = IndexedBytesCache(
        index: FakeBytesIndex(),
        blobs: blobs,
        clock: () => now,
        retention: const BytesRetention.maxEntries(2),
        reclaimOrphans: blobs.reclaimOrphans,
      );
      addTearDown(store.close);
    });

    test('hands out the path of the held payload', () async {
      await put(a);
      final lease = await store.leaseFile(a);
      expect(lease, isNotNull);
      expect(lease!.key, a);
      expect(lease.path, blobs.pathOf(a));
    });

    test('is null for a key that holds nothing', () async {
      expect(await store.leaseFile(a), isNull);
    });

    test('eviction under pressure skips a leased file, then takes it after '
        'release', () async {
      await put(a);
      final lease = (await store.leaseFile(a))!;
      await put(b);
      await put(c);

      expect(blobs.payloads.keys, unorderedEquals(['a', 'c']));
      expect(store.contains(b), isFalse);

      await lease.release();
      await put(d);
      expect(blobs.payloads.keys, unorderedEquals(['c', 'd']));
    });

    test(
      'explicit evict drops the key at once and the file on release',
      () async {
        await put(a);
        final lease = (await store.leaseFile(a))!;
        await store.evict(a);

        expect(store.contains(a), isFalse);
        expect(await store.read(a), isNull);
        expect(blobs.payloads.keys, contains('a'));

        await store.prune();
        expect(blobs.payloads.keys, contains('a'));

        await lease.release();
        expect(blobs.payloads.keys, isNot(contains('a')));
      },
    );

    test('release is idempotent and the second lease keeps the pin', () async {
      await put(a);
      final first = (await store.leaseFile(a))!;
      final second = (await store.leaseFile(a))!;
      await first.release();
      await first.release();
      expect(first.isReleased, isTrue);
      await store.evict(a);
      expect(blobs.payloads.keys, contains('a'));
      await second.release();
      expect(blobs.payloads.keys, isNot(contains('a')));
    });

    test('an expired row is not leased', () async {
      final aging = IndexedBytesCache(
        index: FakeBytesIndex(),
        blobs: FakeBytesBlobStore(),
        clock: () => now,
        retention: const BytesRetention.maxAge(Duration(days: 1)),
      );
      addTearDown(aging.close);
      await aging.write(a, Uint8List.fromList([1]));
      now = now.add(const Duration(days: 2));
      expect(await aging.leaseFile(a), isNull);
    });

    test('a memory store hands out no files', () async {
      final memory = MemoryBytesCache();
      await memory.write(a, Uint8List.fromList([1]));
      expect(await memory.leaseFile(a), isNull);
    });
  });

  group('File lease on the VM store', () {
    test('the leased path holds the bytes and survives pressure', () async {
      final dir = Directory.systemTemp.createTempSync('http_bytes_lease_');
      addTearDown(() => dir.deleteSync(recursive: true));
      var now = DateTime.utc(2026, 1, 1);
      final store = await BytesCache.open(
        directory: dir.path,
        clock: () => now = now.add(const Duration(seconds: 1)),
        retention: const BytesRetention.maxEntries(1),
        throwOnOpenFailure: true,
      );
      addTearDown(store.close);

      const key = BytesCacheKey('clip');
      await store.write(key, Uint8List.fromList([4, 5, 6]));
      final lease = (await store.leaseFile(key))!;
      expect(File(lease.path).readAsBytesSync(), [4, 5, 6]);

      await store.write(const BytesCacheKey('other'), Uint8List.fromList([1]));
      await store.prune();
      expect(File(lease.path).readAsBytesSync(), [4, 5, 6]);

      await lease.release();
      await store.write(const BytesCacheKey('third'), Uint8List.fromList([2]));
      expect(File(lease.path).existsSync(), isFalse);
    });
  });
}
