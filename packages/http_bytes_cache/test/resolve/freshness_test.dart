import 'package:http_bytes_cache/src/bytes_cache.dart';
import 'package:http_bytes_cache/src/http_cache_freshness.dart';
import 'package:test/test.dart';

void main() {
  group('HttpCacheFreshness.isFresh', () {
    final now = DateTime.utc(2024, 6, 1, 12);

    test('null / empty meta is fresh (pre-ETag retain until retention)', () {
      expect(HttpCacheFreshness.isFresh(null, now: now), isTrue);
      expect(
        HttpCacheFreshness.isFresh(const HttpCacheMeta(), now: now),
        isTrue,
      );
    });

    test('validators without Cache-Control / Expires are stale', () {
      expect(
        HttpCacheFreshness.isFresh(
          const HttpCacheMeta(etag: '"v1"'),
          now: now,
        ),
        isFalse,
      );
      expect(
        HttpCacheFreshness.isFresh(
          const HttpCacheMeta(lastModified: 'Wed, 21 Oct 2015 07:28:00 GMT'),
          now: now,
        ),
        isFalse,
      );
    });

    test('max-age still within lifetime is fresh', () {
      final meta = HttpCacheMeta(
        etag: '"v1"',
        cacheControl: 'max-age=3600',
        lastValidatedAt: now.subtract(const Duration(minutes: 10)),
      );
      expect(HttpCacheFreshness.isFresh(meta, now: now), isTrue);
    });

    test('max-age past lifetime is stale', () {
      final meta = HttpCacheMeta(
        etag: '"v1"',
        cacheControl: 'max-age=60',
        lastValidatedAt: now.subtract(const Duration(minutes: 5)),
      );
      expect(HttpCacheFreshness.isFresh(meta, now: now), isFalse);
    });

    test('Age header counts toward current age', () {
      final meta = HttpCacheMeta(
        etag: '"v1"',
        cacheControl: 'max-age=120',
        age: const Duration(seconds: 100),
        lastValidatedAt: now,
      );
      expect(HttpCacheFreshness.isFresh(meta, now: now), isTrue);

      final stale = HttpCacheMeta(
        etag: '"v1"',
        cacheControl: 'max-age=120',
        age: const Duration(seconds: 150),
        lastValidatedAt: now,
      );
      expect(HttpCacheFreshness.isFresh(stale, now: now), isFalse);
    });

    test('Expires in the future is fresh; past is stale', () {
      final fresh = HttpCacheMeta(
        etag: '"v1"',
        expires: now.add(const Duration(hours: 1)),
        date: now.subtract(const Duration(minutes: 1)),
        lastValidatedAt: now.subtract(const Duration(minutes: 1)),
      );
      expect(HttpCacheFreshness.isFresh(fresh, now: now), isTrue);

      final stale = HttpCacheMeta(
        etag: '"v1"',
        expires: now.subtract(const Duration(minutes: 1)),
        date: now.subtract(const Duration(hours: 1)),
        lastValidatedAt: now.subtract(const Duration(hours: 1)),
      );
      expect(HttpCacheFreshness.isFresh(stale, now: now), isFalse);
    });

    test('Expires-only meta uses absolute wall time', () {
      expect(
        HttpCacheFreshness.isFresh(
          HttpCacheMeta(expires: now.add(const Duration(hours: 1))),
          now: now,
        ),
        isTrue,
      );
      expect(
        HttpCacheFreshness.isFresh(
          HttpCacheMeta(expires: now.subtract(const Duration(minutes: 1))),
          now: now,
        ),
        isFalse,
      );
    });

    test('no-cache and must-revalidate are always stale', () {
      expect(
        HttpCacheFreshness.isFresh(
          const HttpCacheMeta(etag: '"v1"', cacheControl: 'no-cache'),
          now: now,
        ),
        isFalse,
      );
      expect(
        HttpCacheFreshness.isFresh(
          const HttpCacheMeta(etag: '"v1"', cacheControl: 'max-age=3600, must-revalidate'),
          now: now,
        ),
        isFalse,
      );
    });

    test('immutable is fresh even with validators', () {
      expect(
        HttpCacheFreshness.isFresh(
          HttpCacheMeta(
            etag: '"static"',
            cacheControl: 'public, max-age=0, immutable',
            lastValidatedAt: now.subtract(const Duration(days: 30)),
          ),
          now: now,
        ),
        isTrue,
      );
    });
  });

  group('HttpCacheFreshness.fromResponseHeaders', () {
    test('captures validators and freshness fields', () {
      final validatedAt = DateTime.utc(2024, 6, 1, 12);
      final meta = HttpCacheFreshness.fromResponseHeaders(
        {
          'ETag': '"abc"',
          'Last-Modified': 'Wed, 21 Oct 2015 07:28:00 GMT',
          'Cache-Control': 'max-age=60',
          'Date': 'Sat, 01 Jun 2024 12:00:00 GMT',
          'Age': '12',
        },
        validatedAt: validatedAt,
      );

      expect(meta?.etag, '"abc"');
      expect(meta?.lastModified, 'Wed, 21 Oct 2015 07:28:00 GMT');
      expect(meta?.cacheControl, 'max-age=60');
      expect(meta?.date, DateTime.utc(2024, 6, 1, 12));
      expect(meta?.age, const Duration(seconds: 12));
      expect(meta?.lastValidatedAt, validatedAt);
    });

    test('empty headers yield null', () {
      expect(
        HttpCacheFreshness.fromResponseHeaders(
          const {},
          validatedAt: DateTime.utc(2024, 1, 1),
        ),
        isNull,
      );
    });
  });

  group('HttpCacheFreshness.afterNotModified', () {
    test('keeps prior etag when 304 omits it and bumps lastValidatedAt', () {
      const prior = HttpCacheMeta(
        etag: '"old"',
        cacheControl: 'max-age=60',
      );
      final validatedAt = DateTime.utc(2024, 6, 2);
      final next = HttpCacheFreshness.afterNotModified(
        prior,
        headers: const {'cache-control': 'max-age=120'},
        validatedAt: validatedAt,
      );

      expect(next.etag, '"old"');
      expect(next.cacheControl, 'max-age=120');
      expect(next.lastValidatedAt, validatedAt);
    });
  });
}
