// Integration coverage for BytesCache.open on web (Cache API + OPFS).
//
// Run with:
// dart test -p chrome test/open/open_web_test.dart
//
// Skipped on the VM compiler: package:web / Cache Storage / OPFS are browser-only.
@TestOn('chrome')
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:http_bytes_cache/src/bytes_cache.dart';
import 'package:http_bytes_cache/src/bytes_web_keys.dart';
import 'package:http_bytes_cache/src/environment_specific/blob_store_routed_js.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

Future<void> _wipeDurableWebStorage() async {
  await web.window.caches.delete(BytesWebKeys.indexCacheName).toDart;
  await web.window.caches.delete(BytesWebKeys.blobsCacheName).toDart;
  final root = await web.window.navigator.storage.getDirectory().toDart;
  try {
    await root
        .removeEntry(
          BytesWebKeys.opfsBlobsDirectoryName,
          web.FileSystemRemoveOptions(recursive: true),
        )
        .toDart;
  } on Object {
    // Missing directory is fine between tests.
  }
}

Future<bool> _cacheHas(BytesCacheKey key) async {
  final blobs = await web.window.caches.open(BytesWebKeys.blobsCacheName).toDart;
  final match = await blobs.match(BytesWebKeys.blobUrl(key).toJS).toDart;
  return match != null;
}

Future<bool> _opfsHas(BytesCacheKey key) async {
  final root = await web.window.navigator.storage.getDirectory().toDart;
  try {
    final dir = await root.getDirectoryHandle(BytesWebKeys.opfsBlobsDirectoryName).toDart;
    await dir.getFileHandle(key.value).toDart;
    return true;
  } on Object {
    return false;
  }
}

Uint8List _filled(int length, int fill) {
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = (fill + i) & 0xff;
  }
  return bytes;
}

void main() {
  tearDown(_wipeDurableWebStorage);

  group('BytesCache.open (web)', () {
    test('directory argument is ignored and small payload round-trips via Cache API', () async {
      const key = BytesCacheKey('small_svg');
      final bytes = Uint8List.fromList([1, 2, 3, 4]);

      final first = await BytesCache.open(
        directory: '/ignored/on/web',
        retention: const BytesRetention.unlimited(),
      );
      await first.write(key, bytes);
      await first.close();

      expect(await _cacheHas(key), isTrue);
      expect(await _opfsHas(key), isFalse);

      final second = await BytesCache.open(
        retention: const BytesRetention.unlimited(),
      );
      addTearDown(second.close);

      expect(await second.read(key), bytes);
    });

    test('payload at or above threshold round-trips via OPFS', () async {
      const key = BytesCacheKey('large_raster');
      final bytes = _filled(BytesBlobStore$Routed$JS.opfsByteThreshold, 7);

      final first = await BytesCache.open(
        retention: const BytesRetention.unlimited(),
      );
      await first.write(key, bytes);
      await first.close();

      expect(await _opfsHas(key), isTrue);
      expect(await _cacheHas(key), isFalse);

      final second = await BytesCache.open(
        retention: const BytesRetention.unlimited(),
      );
      addTearDown(second.close);

      expect(await second.read(key), bytes);
    });

    test('large-body hot read prefers OPFS when index byteLength implies it', () async {
      // Without a size hint, Cache-then-OPFS would return this poison twin.
      // Index meta already knows the body is ≥ threshold, so the hot path must
      // skip Cache and return the OPFS payload.
      const key = BytesCacheKey('large_with_poison_cache');
      final large = _filled(BytesBlobStore$Routed$JS.opfsByteThreshold, 11);
      final poison = Uint8List.fromList([1, 2, 3]);

      final cache = await BytesCache.open(
        retention: const BytesRetention.unlimited(),
      );
      addTearDown(cache.close);

      await cache.write(key, large);
      expect(await _opfsHas(key), isTrue);
      expect(await _cacheHas(key), isFalse);

      final blobs = await web.window.caches.open(BytesWebKeys.blobsCacheName).toDart;
      await blobs
          .put(
            BytesWebKeys.blobUrl(key).toJS,
            web.Response(poison.toJS),
          )
          .toDart;
      expect(await _cacheHas(key), isTrue);

      expect(await cache.read(key), large);
    });

    test('rewrite across threshold moves the body between backends', () async {
      const key = BytesCacheKey('resize');
      final small = Uint8List.fromList([9, 8, 7]);
      final large = _filled(BytesBlobStore$Routed$JS.opfsByteThreshold, 3);

      final cache = await BytesCache.open(
        retention: const BytesRetention.unlimited(),
      );
      addTearDown(cache.close);

      await cache.write(key, small);
      expect(await _cacheHas(key), isTrue);
      expect(await _opfsHas(key), isFalse);

      await cache.write(key, large);
      expect(await _opfsHas(key), isTrue);
      expect(await _cacheHas(key), isFalse);
      expect(await cache.read(key), large);

      await cache.write(key, small);
      expect(await _cacheHas(key), isTrue);
      expect(await _opfsHas(key), isFalse);
      expect(await cache.read(key), small);
    });

    test('orphan Cache blob without index is reclaimed on open', () async {
      final blobs = await web.window.caches.open(BytesWebKeys.blobsCacheName).toDart;
      await blobs
          .put(
            BytesWebKeys.blobUrl(const BytesCacheKey('orphan')).toJS,
            web.Response(Uint8List.fromList([1, 2, 3]).toJS),
          )
          .toDart;

      final cache = await BytesCache.open(
        retention: const BytesRetention.unlimited(),
      );
      addTearDown(cache.close);

      expect(await cache.read(const BytesCacheKey('orphan')), isNull);
      final leftover = await blobs.match(BytesWebKeys.blobUrl(const BytesCacheKey('orphan')).toJS).toDart;
      expect(leftover, isNull);
    });

    test('orphan OPFS blob without index is reclaimed on open', () async {
      final root = await web.window.navigator.storage.getDirectory().toDart;
      final dir = await root
          .getDirectoryHandle(
            BytesWebKeys.opfsBlobsDirectoryName,
            web.FileSystemGetDirectoryOptions(create: true),
          )
          .toDart;
      final handle = await dir
          .getFileHandle(
            'opfs_orphan',
            web.FileSystemGetFileOptions(create: true),
          )
          .toDart;
      final writable = await handle.createWritable().toDart;
      await writable.write(Uint8List.fromList([5, 5, 5]).toJS).toDart;
      await writable.close().toDart;

      final cache = await BytesCache.open(
        retention: const BytesRetention.unlimited(),
      );
      addTearDown(cache.close);

      expect(await cache.read(const BytesCacheKey('opfs_orphan')), isNull);
      expect(await _opfsHas(const BytesCacheKey('opfs_orphan')), isFalse);
    });

    test('orphan blob without index is reclaimed on prune', () async {
      final cache = await BytesCache.open(
        retention: const BytesRetention.unlimited(),
      );
      addTearDown(cache.close);

      await cache.write(const BytesCacheKey('kept'), Uint8List.fromList([4]));

      final blobs = await web.window.caches.open(BytesWebKeys.blobsCacheName).toDart;
      await blobs
          .put(
            BytesWebKeys.blobUrl(const BytesCacheKey('stray')).toJS,
            web.Response(Uint8List.fromList([5, 6]).toJS),
          )
          .toDart;

      await cache.prune();

      expect(await cache.read(const BytesCacheKey('kept')), Uint8List.fromList([4]));
      final leftover = await blobs.match(BytesWebKeys.blobUrl(const BytesCacheKey('stray')).toJS).toDart;
      expect(leftover, isNull);
    });

    test('close is idempotent and rejects later ops', () async {
      final cache = await BytesCache.open(
        retention: const BytesRetention.unlimited(),
      );
      await cache.write(const BytesCacheKey('a'), Uint8List.fromList([1]));
      await cache.close();
      await cache.close();

      await expectLater(
        cache.read(const BytesCacheKey('a')),
        throwsA(isA<StateError>()),
      );
    });
  });
}
