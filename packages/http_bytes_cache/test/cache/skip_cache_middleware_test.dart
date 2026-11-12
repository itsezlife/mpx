import 'dart:typed_data';

import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:test/test.dart';

void main() {
  group('SkipCacheMiddleware', () {
    test('seeded skip makes read miss without touching stored bytes', () async {
      final inner = MemoryBytesCache();
      const key = BytesCacheKey('logo');
      final bytes = Uint8List.fromList([1, 2, 3]);
      await inner.write(key, bytes);

      final cache = MiddlewareBytesCache(
        inner: inner,
        middlewares: <CacheMiddleware>[const SkipCacheMiddleware()],
      );
      final context = CacheContext.empty()..skipCache = true;

      final result = await cache.execute(const CacheOperation$Read(key), context);

      expect(result, isA<CacheOperationResult$Read>().having((r) => r.hit, 'hit', isNull));
      expect(await inner.read(key), bytes);
    });

    test('seeded skip makes write a no-op', () async {
      final inner = MemoryBytesCache();
      const key = BytesCacheKey('logo');
      final cache = MiddlewareBytesCache(
        inner: inner,
        middlewares: <CacheMiddleware>[const SkipCacheMiddleware()],
      );
      final context = CacheContext.empty()..skipCache = true;

      await cache.execute(
        CacheOperation$Write(key, Uint8List.fromList([9, 9])),
        context,
      );

      expect(await inner.read(key), isNull);
    });

    test('without skip, read and write reach the inner store', () async {
      final inner = MemoryBytesCache();
      const key = BytesCacheKey('logo');
      final bytes = Uint8List.fromList([4, 5]);
      final cache = MiddlewareBytesCache(
        inner: inner,
        middlewares: <CacheMiddleware>[const SkipCacheMiddleware()],
      );

      await cache.write(key, bytes);

      expect(await cache.read(key), bytes);
      expect(await inner.read(key), bytes);
    });

    test('shouldSkip predicate skips without a context flag', () async {
      final inner = MemoryBytesCache();
      const key = BytesCacheKey('secret');
      await inner.write(key, Uint8List.fromList([1]));

      final cache = MiddlewareBytesCache(
        inner: inner,
        middlewares: <CacheMiddleware>[
          SkipCacheMiddleware(
            shouldSkip: (operation, _) => switch (operation) {
              CacheOperation$Read(:final key) || CacheOperation$Write(:final key) => key.value.contains('secret'),
              _ => false,
            },
          ),
        ],
      );

      expect(await cache.read(key), isNull);
      await cache.write(key, Uint8List.fromList([2]));
      expect(await inner.read(key), Uint8List.fromList([1]));
    });
  });
}
