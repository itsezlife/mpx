import 'dart:typed_data';

import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:test/test.dart';

void main() {
  group(r'CacheLoggerMiddleware$Developer', () {
    test('emits hit and miss without changing stored bytes', () async {
      final lines = <String>[];
      final inner = MemoryBytesCache();
      const key = BytesCacheKey('logo');
      final bytes = Uint8List.fromList([1, 2]);
      await inner.write(key, bytes);

      final cache = MiddlewareBytesCache(
        inner: inner,
        middlewares: <CacheMiddleware>[
          CacheLoggerMiddleware$Developer(
            debugEmit: (message, {required level, stackTrace}) {
              lines.add(message);
            },
          ),
        ],
      );

      expect(await cache.read(key), bytes);
      expect(await cache.read(const BytesCacheKey('missing')), isNull);
      expect(await inner.read(key), bytes);

      expect(lines, hasLength(2));
      expect(lines.first, contains('read hit'));
      expect(lines.first, contains('logo'));
      expect(lines.first, contains('2 B'));
      expect(lines.last, contains('read miss'));
      expect(lines.last, contains('missing'));
    });

    test('formats larger hit sizes like HTTP logger', () async {
      final lines = <String>[];
      final inner = MemoryBytesCache();
      const key = BytesCacheKey('big');
      // 1536 bytes → 1.5 KB
      final bytes = Uint8List(1536);
      await inner.write(key, bytes);

      final cache = MiddlewareBytesCache(
        inner: inner,
        middlewares: <CacheMiddleware>[
          CacheLoggerMiddleware$Developer(
            debugEmit: (message, {required level, stackTrace}) {
              lines.add(message);
            },
          ),
        ],
      );

      expect(await cache.read(key), bytes);
      expect(lines.single, contains('read hit (1.5 KB)'));
    });

    test('emits evict and prune without reclaim', () async {
      final lines = <String>[];
      final inner = MemoryBytesCache(
        retention: const BytesRetention.maxAge(Duration(hours: 1)),
      );
      const key = BytesCacheKey('logo');
      final cache = MiddlewareBytesCache(
        inner: inner,
        middlewares: <CacheMiddleware>[
          CacheLoggerMiddleware$Developer(
            debugEmit: (message, {required level, stackTrace}) {
              lines.add(message);
            },
          ),
        ],
      );
      await cache.write(key, Uint8List.fromList([1]));
      lines.clear();

      await cache.evict(key);
      expect(await inner.read(key), isNull);

      final report = await cache.prune();
      expect(report.evictedKeys, isEmpty);

      expect(lines, hasLength(2));
      expect(lines.first, contains('evict ok'));
      expect(lines.last, contains('prune ok'));
    });

    test('emission failures do not fail the cache op', () async {
      final inner = MemoryBytesCache();
      final cache = MiddlewareBytesCache(
        inner: inner,
        middlewares: <CacheMiddleware>[
          CacheLoggerMiddleware$Developer(
            debugEmit: (message, {required level, stackTrace}) {
              throw StateError('sink broken');
            },
          ),
        ],
      );
      const key = BytesCacheKey('safe');
      final bytes = Uint8List.fromList([9]);

      await cache.write(key, bytes);
      expect(await cache.read(key), bytes);
    });

    test('observes skip-cache miss without writing through', () async {
      final lines = <String>[];
      final inner = MemoryBytesCache();
      const key = BytesCacheKey('logo');
      await inner.write(key, Uint8List.fromList([1]));

      final cache = MiddlewareBytesCache(
        inner: inner,
        middlewares: <CacheMiddleware>[
          CacheLoggerMiddleware$Developer(
            debugEmit: (message, {required level, stackTrace}) {
              lines.add(message);
            },
          ),
          const SkipCacheMiddleware(),
        ],
      );
      final context = CacheContext.empty()..skipCache = true;

      final result = await cache.execute(const CacheOperation$Read(key), context);
      expect(result, isA<CacheOperationResult$Read>().having((r) => r.hit, 'hit', isNull));
      expect(await inner.read(key), Uint8List.fromList([1]));
      expect(lines.single, contains('read miss'));
    });
  });
}
