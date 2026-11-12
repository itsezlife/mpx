import 'dart:typed_data';

import 'package:http_bytes_cache/src/bytes_cache.dart';
import 'package:test/test.dart';

void main() {
  group('MemoryBytesCache', () {
    test('write then read returns the same bytes', () async {
      final cache = MemoryBytesCache();
      const key = BytesCacheKey('logo');
      final bytes = Uint8List.fromList([1, 2, 3]);

      await cache.write(key, bytes);

      expect(await cache.read(key), bytes);
    });

    test('read miss returns null', () async {
      final cache = MemoryBytesCache();

      expect(await cache.read(const BytesCacheKey('missing')), isNull);
    });

    test('TTL: read after maxAge returns null and evicts', () async {
      var now = DateTime.utc(2024, 1, 1, 12);
      final cache = MemoryBytesCache(
        retention: const BytesRetention.maxAge(Duration(hours: 1)),
        clock: () => now,
      );
      const key = BytesCacheKey('logo');
      await cache.write(key, Uint8List.fromList([1]));

      now = now.add(const Duration(hours: 2));

      expect(await cache.read(key), isNull);
      expect(await cache.read(key), isNull);
    });

    test('TTL: read within maxAge still hits', () async {
      var now = DateTime.utc(2024, 1, 1, 12);
      final cache = MemoryBytesCache(
        retention: const BytesRetention.maxAge(Duration(hours: 1)),
        clock: () => now,
      );
      const key = BytesCacheKey('logo');
      final bytes = Uint8List.fromList([9]);
      await cache.write(key, bytes);

      now = now.add(const Duration(minutes: 30));

      expect(await cache.read(key), bytes);
    });

    test('maxEntries: write evicts oldest accessed', () async {
      var now = DateTime.utc(2024, 1, 1);
      final cache = MemoryBytesCache(
        retention: const BytesRetention.maxEntries(2),
        clock: () => now,
      );

      await cache.write(const BytesCacheKey('a'), Uint8List.fromList([1]));
      now = now.add(const Duration(seconds: 1));
      await cache.write(const BytesCacheKey('b'), Uint8List.fromList([2]));
      now = now.add(const Duration(seconds: 1));
      // Touch a so b becomes oldest.
      await cache.read(const BytesCacheKey('a'));
      now = now.add(const Duration(seconds: 1));
      await cache.write(const BytesCacheKey('c'), Uint8List.fromList([3]));

      expect(
        await cache.read(const BytesCacheKey('a')),
        Uint8List.fromList([1]),
      );
      expect(await cache.read(const BytesCacheKey('b')), isNull);
      expect(
        await cache.read(const BytesCacheKey('c')),
        Uint8List.fromList([3]),
      );
    });

    test('prune removes expired and reports keys', () async {
      var now = DateTime.utc(2024, 6, 1);
      final cache = MemoryBytesCache(
        retention: const BytesRetention.maxAge(Duration(days: 1)),
        clock: () => now,
      );
      await cache.write(const BytesCacheKey('old'), Uint8List.fromList([1]));
      now = now.add(const Duration(days: 2));
      await cache.write(const BytesCacheKey('fresh'), Uint8List.fromList([2]));

      final report = await cache.prune();

      expect(report.evictedKeys, [const BytesCacheKey('old')]);
      expect(await cache.read(const BytesCacheKey('old')), isNull);
      expect(
        await cache.read(const BytesCacheKey('fresh')),
        Uint8List.fromList([2]),
      );
    });

    test('evict removes a single key', () async {
      final cache = MemoryBytesCache();
      const key = BytesCacheKey('logo');
      await cache.write(key, Uint8List.fromList([1]));

      await cache.evict(key);

      expect(await cache.read(key), isNull);
    });

    test('empty write is not retained as capacity waste', () async {
      final cache = MemoryBytesCache(
        retention: const BytesRetention.maxEntries(1),
      );
      const emptyKey = BytesCacheKey('empty');
      const keepKey = BytesCacheKey('keep');

      await cache.write(emptyKey, Uint8List(0));
      expect(await cache.read(emptyKey), isNull);

      await cache.write(keepKey, Uint8List.fromList([1]));
      expect(await cache.read(keepKey), Uint8List.fromList([1]));
    });

    test(
      'empty write evicts a previously stored payload for the same key',
      () async {
        final cache = MemoryBytesCache();
        const key = BytesCacheKey('logo');
        await cache.write(key, Uint8List.fromList([1, 2]));

        await cache.write(key, Uint8List(0));

        expect(await cache.read(key), isNull);
      },
    );
  });

  group('NoOpBytesCache', () {
    test('read always returns null and write succeeds', () async {
      const cache = NoOpBytesCache();
      const key = BytesCacheKey('logo');

      await cache.write(key, Uint8List.fromList([1]));

      expect(await cache.read(key), isNull);
      expect(
        await cache.prune(),
        const BytesPruneReport(evictedKeys: [], freedBytes: 0),
      );
    });
  });

  group('BytesCacheKey.fromUrl', () {
    test('produces safe key with host path and hash', () {
      final key = BytesCacheKey.fromUrl(
        'https://cdn.example.com/icons/logo.svg',
      );
      expect(key.value, contains('cdn_example_com'));
      expect(key.value, contains('logo'));
      expect(key.value, isNot(contains('/')));
      expect(key.value, isNot(contains(r'\')));
    });

    test('strips path traversal and reserved characters', () {
      final key = BytesCacheKey.fromUrl(
        'https://cdn.example.com/../../etc/passwd?x=1',
      );
      expect(key.value, isNot(contains('..')));
      expect(key.value, isNot(contains('/')));
    });

    test('different query strings yield different keys', () {
      final a = BytesCacheKey.fromUrl('https://x.test/a.svg?v=1');
      final b = BytesCacheKey.fromUrl('https://x.test/a.svg?v=2');
      expect(a, isNot(equals(b)));
    });

    test('different headers yield different keys', () {
      final a = BytesCacheKey.fromUrl(
        'https://x.test/a.svg',
        headers: const {'Authorization': 'a'},
      );
      final b = BytesCacheKey.fromUrl(
        'https://x.test/a.svg',
        headers: const {'Authorization': 'b'},
      );
      expect(a, isNot(equals(b)));
    });

    test('conditional request headers do not change identity', () {
      final plain = BytesCacheKey.fromUrl('https://x.test/a.svg');
      final withValidators = BytesCacheKey.fromUrl(
        'https://x.test/a.svg',
        headers: const {
          'If-None-Match': '"v1"',
          'If-Modified-Since': 'Wed, 21 Oct 2015 07:28:00 GMT',
          'If-Match': '"v0"',
          'If-Unmodified-Since': 'Wed, 21 Oct 2015 07:28:00 GMT',
          'If-Range': '"v1"',
        },
      );
      final mixedCase = BytesCacheKey.fromUrl(
        'https://x.test/a.svg',
        headers: const {'if-none-match': '"other"'},
      );
      expect(withValidators, equals(plain));
      expect(mixedCase, equals(plain));
      expect(
        BytesCacheKey.canonicalHeaders(const {
          'If-None-Match': '"v1"',
          'Authorization': 't',
        }),
        equals(BytesCacheKey.canonicalHeaders(const {'Authorization': 't'})),
      );
      // Authorization still participates; only conditionals are stripped.
      expect(
        BytesCacheKey.fromUrl(
          'https://x.test/a.svg',
          headers: const {'Authorization': 'a', 'If-None-Match': '"v1"'},
        ),
        isNot(
          equals(
            BytesCacheKey.fromUrl(
              'https://x.test/a.svg',
              headers: const {'Authorization': 'b', 'If-None-Match': '"v1"'},
            ),
          ),
        ),
      );
    });

    test('header key casing does not change identity', () {
      final a = BytesCacheKey.fromUrl(
        'https://x.test/a.svg',
        headers: const {'Authorization': 'token'},
      );
      final b = BytesCacheKey.fromUrl(
        'https://x.test/a.svg',
        headers: const {'authorization': 'token'},
      );
      expect(a, equals(b));
    });

    test('header key order does not change identity', () {
      final a = BytesCacheKey.fromUrl(
        'https://x.test/a.svg',
        headers: const {'a': '1', 'b': '2'},
      );
      final b = BytesCacheKey.fromUrl(
        'https://x.test/a.svg',
        headers: const {'b': '2', 'a': '1'},
      );
      expect(a, equals(b));
    });

    test('same basename under different paths yields different keys', () {
      final a = BytesCacheKey.fromUrl('https://x.test/foo/logo.svg');
      final b = BytesCacheKey.fromUrl('https://x.test/bar/logo.svg');
      expect(a, isNot(equals(b)));
    });

    test('long basename stays within length cap and remains distinct', () {
      final longName = '${'a' * 200}.svg';
      final a = BytesCacheKey.fromUrl(
        'https://cdn.example.com/icons/$longName',
      );
      final b = BytesCacheKey.fromUrl(
        'https://cdn.example.com/other/$longName',
      );
      expect(a.value.length, lessThanOrEqualTo(180));
      expect(b.value.length, lessThanOrEqualTo(180));
      expect(a, isNot(equals(b)));
    });

    test('relative and absolute Uri.base equivalents share one key', () {
      const relative = 'icons/logo.svg';
      final absolute = Uri.base.resolve(relative).toString();
      expect(
        BytesCacheKey.fromUrl(relative),
        equals(BytesCacheKey.fromUrl(absolute)),
      );
    });

    test(
      'URL containing |… without headers differs from clean URL plus those headers',
      () {
        final poisoned = BytesCacheKey.fromUrl(
          'https://cdn.example.com/a.svg|authorization=Bearer x',
        );
        final clean = BytesCacheKey.fromUrl(
          'https://cdn.example.com/a.svg',
          headers: const {'Authorization': 'Bearer x'},
        );
        expect(poisoned, isNot(equals(clean)));
      },
    );

    test(
      'pipe inside a header value cannot forge another URL+headers fingerprint',
      () {
        final withPipeInValue = BytesCacheKey.fromUrl(
          'https://cdn.example.com/a.svg',
          headers: const {'authorization': 'Bearer x|foo=bar'},
        );
        final withPipeInUrl = BytesCacheKey.fromUrl(
          'https://cdn.example.com/a.svg|authorization=Bearer x',
          headers: const {'foo': 'bar'},
        );
        expect(withPipeInValue, isNot(equals(withPipeInUrl)));
        // Same host/basename would still collide if fingerprint material used a
        // raw `url|headers` join — assert the trailing fingerprint segments differ.
        expect(
          withPipeInValue.value.substring(withPipeInValue.value.length - 12),
          isNot(
            equals(
              withPipeInUrl.value.substring(withPipeInUrl.value.length - 12),
            ),
          ),
        );
      },
    );
  });

  group('BytesRetention.standard', () {
    test('includes maxAge, maxEntries, and maxBytes', () {
      final limits = BytesRetention.standard.limits;
      expect(limits.maxAge, const Duration(days: 14));
      expect(limits.maxEntries, 500);
      expect(limits.maxBytes, 50 * 1024 * 1024);
    });
  });

  group('BytesRetention capacity invariants', () {
    test('rejects non-positive maxEntries', () {
      expect(
        () => BytesRetention.maxEntries(0),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => BytesRetention.maxEntries(-1),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => BytesRetention.compound(maxEntries: 0),
        throwsA(isA<AssertionError>()),
      );
    });

    test('rejects non-positive maxBytes', () {
      expect(
        () => BytesRetention.maxBytes(0),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => BytesRetention.maxBytes(-1),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => BytesRetention.compound(maxBytes: 0),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('close', () {
    test('MemoryBytesCache close is idempotent', () async {
      final cache = MemoryBytesCache();
      await cache.close();
      await cache.close();
      await cache.write(const BytesCacheKey('logo'), Uint8List.fromList([1]));
      expect(
        await cache.read(const BytesCacheKey('logo')),
        Uint8List.fromList([1]),
      );
    });

    test('NoOpBytesCache close is idempotent', () async {
      const cache = NoOpBytesCache();
      await cache.close();
      await cache.close();
      expect(await cache.read(const BytesCacheKey('logo')), isNull);
    });
  });

  group('BytesCache.configure', () {
    tearDown(() async {
      await BytesCache.resetShared();
    });

    test('closes the previous shared instance before replace', () async {
      final first = _ClosableProbeCache();
      final second = _ClosableProbeCache();

      await BytesCache.configure(first);
      expect(identical(BytesCache.shared(), first), isTrue);

      first.onClose = () {
        expect(
          identical(BytesCache.shared(), first),
          isTrue,
          reason: 'previous must still be shared until close finishes',
        );
      };

      await BytesCache.configure(second);
      expect(identical(BytesCache.shared(), second), isTrue);
      expect(first.closeCount, 1);
      expect(second.closeCount, 0);
    });

    test('resetShared closes then clears', () async {
      final probe = _ClosableProbeCache();
      await BytesCache.configure(probe);
      probe.onClose = () {
        expect(
          identical(BytesCache.shared(), probe),
          isTrue,
          reason: 'shared must stay until close finishes',
        );
      };

      await BytesCache.resetShared();
      expect(probe.closeCount, 1);
      expect(BytesCache.shared(), isA<NoOpBytesCache>());
    });
  });
}

final class _ClosableProbeCache implements IBytesCache {
  int closeCount = 0;
  void Function()? onClose;

  @override
  Future<Uint8List?> read(BytesCacheKey key) async => null;

  @override
  Future<void> write(
    BytesCacheKey key,
    Uint8List bytes, {
    HttpCacheMeta? httpCacheMeta,
  }) async {}

  @override
  Future<void> evict(BytesCacheKey key) async {}

  @override
  Future<BytesPruneReport> prune() async =>
      const BytesPruneReport(evictedKeys: [], freedBytes: 0);

  @override
  Future<void> close() async {
    closeCount++;
    onClose?.call();
  }
}
