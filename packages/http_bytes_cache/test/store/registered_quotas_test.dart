import 'dart:io';
import 'dart:typed_data';

import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:http_bytes_cache/testing.dart';
import 'package:test/test.dart';

const _images = BytesQuota('images', maxBytes: 100);
const _frames = BytesQuota('lottie_frames', maxBytes: 50);

/// Owns a folder of [usedBytes]; frees what it is asked, up to [canFree].
final class _FakeOwner {
  _FakeOwner(this.usedBytes, {int? canFree}) : canFree = canFree ?? usedBytes;

  int usedBytes;
  int canFree;
  final List<int> asks = [];

  Future<int> evict(int bytes) async {
    asks.add(bytes);
    final freed = bytes < canFree ? bytes : canFree;
    canFree -= freed;
    usedBytes -= freed;
    return freed;
  }
}

void main() {
  late DateTime now;
  late FakeBytesIndex index;

  IndexedBytesCache open({
    BytesRetention retention = const BytesRetention.unlimited(),
  }) {
    final store = IndexedBytesCache(
      index: index,
      blobs: FakeBytesBlobStore(),
      clock: () => now = now.add(const Duration(seconds: 1)),
      retention: retention,
      quotas: const [_images, _frames],
    );
    addTearDown(store.close);
    return store;
  }

  setUp(() {
    now = DateTime.utc(2026, 1, 1);
    index = FakeBytesIndex();
  });

  group('Registered quotas', () {
    test('over its own share, the owner is asked for the excess', () async {
      final store = open();
      final owner = _FakeOwner(80);
      final registered = store.registerQuota(_frames, onEvict: owner.evict)
        ..reportUsage(owner.usedBytes);
      await store.prune();

      expect(owner.asks, [30]);
      expect(registered.usedBytes, 50);
    });

    test('under total pressure, the owner furthest over its share gives back '
        'and the store rows stay', () async {
      final store = open(retention: const BytesRetention.maxBytes(100));
      final owner = _FakeOwner(45);
      store
          .registerQuota(_frames, onEvict: owner.evict)
          .reportUsage(owner.usedBytes);
      await store.write(const BytesCacheKey('avatar'), Uint8List(60));

      // frames 45/50 vs images 60/100: frames give back the 5 over budget.
      expect(owner.asks, [5]);
      expect(index.records.keys, ['avatar']);
    });

    test(
      'an owner that frees too little leaves the rest to other quotas',
      () async {
        final store = open(retention: const BytesRetention.maxBytes(100));
        final owner = _FakeOwner(45, canFree: 0);
        store
            .registerQuota(_frames, onEvict: owner.evict)
            .reportUsage(owner.usedBytes);
        await store.write(const BytesCacheKey('a'), Uint8List(30));
        await store.write(const BytesCacheKey('b'), Uint8List(30));

        expect(owner.asks, isNotEmpty);
        expect(index.records.keys, ['b']);
      },
    );

    test(
      'a usage report over budget asks without waiting for a write',
      () async {
        final store = open();
        final owner = _FakeOwner(0);
        final registered = store.registerQuota(_frames, onEvict: owner.evict);
        owner.usedBytes = 70;
        registered.reportUsage(70);
        await pumpEventQueue();

        expect(owner.asks, [20]);
      },
    );

    test('an unregistered quota is neither counted nor asked', () async {
      final store = open(retention: const BytesRetention.maxBytes(100));
      final owner = _FakeOwner(90);
      store.registerQuota(_frames, onEvict: owner.evict)
        ..reportUsage(owner.usedBytes)
        ..unregister();
      await store.write(const BytesCacheKey('avatar'), Uint8List(60));
      await pumpEventQueue();

      expect(owner.asks, isEmpty);
      expect(index.records.keys, ['avatar']);
    });

    test('registering one name twice is refused', () {
      final store = open()..registerQuota(_frames, onEvict: (_) async => 0);
      expect(
        () => store.registerQuota(_frames, onEvict: (_) async => 0),
        throwsStateError,
      );
    });
  });

  group('Registered quotas on the VM store', () {
    test('the store never deletes in a registered folder', () async {
      final root = Directory.systemTemp.createTempSync('http_bytes_foreign_');
      addTearDown(() => root.deleteSync(recursive: true));
      final frames = Directory('${root.path}/frames')..createSync();
      final frame = File('${frames.path}/0001.bin')
        ..writeAsBytesSync(List.filled(80, 1));

      final store = await BytesCache.open(
        directory: root.path,
        quotas: const [_images, _frames],
        throwOnOpenFailure: true,
      );
      addTearDown(store.close);
      final owner = _FakeOwner(80, canFree: 0);
      store
          .registerQuota(_frames, onEvict: owner.evict)
          .reportUsage(owner.usedBytes);
      await store.write(const BytesCacheKey('avatar'), Uint8List(10));
      await store.prune();

      expect(owner.asks, isNotEmpty);
      expect(frame.existsSync(), isTrue);
    });
  });
}
