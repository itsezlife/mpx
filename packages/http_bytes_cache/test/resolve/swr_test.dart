import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:test/test.dart';

void main() {
  group('RevalidationPolicy', () {
    const key = BytesCacheKey('avatar-7');
    const url = 'https://cdn.example.com/avatar-7.jpg';
    final old = Uint8List.fromList([1, 1]);
    late DateTime now;
    late MemoryBytesCache cache;
    late List<http.Request> sent;
    late Completer<http.Response> answer;
    late BytesResolver resolver;

    BytesRequest request(RevalidationPolicy policy) =>
        BytesRequest(url: url, cacheKey: key, revalidation: policy);

    setUp(() async {
      now = DateTime.utc(2026, 1, 1);
      cache = MemoryBytesCache(clock: () => now);
      // Always stale: validators plus no-cache.
      await cache.write(
        key,
        old,
        httpCacheMeta: const HttpCacheMeta(
          etag: '"v1"',
          cacheControl: 'no-cache',
        ),
      );
      sent = [];
      answer = Completer<http.Response>();
      final client = HttpBytesClient(
        middlewares: <HttpBytesMiddleware>[
          const HttpBytesConditionalMiddleware(),
        ],
        client: MockClient((r) {
          sent.add(r);
          return answer.future;
        }),
      );
      addTearDown(client.close);
      resolver = BytesResolver(cache: cache, client: client, clock: () => now);
    });

    test('stale-while-revalidate serves stale bytes at once', () async {
      final result = await resolver.resolveRich(
        request(RevalidationPolicy.staleWhileRevalidate),
      );

      expect(result.bytes, old);
      expect(result.origin, BytesOrigin.cache);
      await pumpEventQueue();
      expect(sent.single.headers['If-None-Match'], '"v1"');
      answer.complete(http.Response.bytes(const [], 304));
    });

    test('a background 304 refreshes metadata only', () async {
      await resolver.resolve(request(RevalidationPolicy.staleWhileRevalidate));
      answer.complete(
        http.Response.bytes(
          const [],
          304,
          headers: {'etag': '"v1"', 'cache-control': 'max-age=60'},
        ),
      );
      await pumpEventQueue();

      final hit = (await cache.readRich(key))!;
      expect(hit.bytes, old);
      expect(hit.httpCacheMeta!.cacheControl, 'max-age=60');
      expect(hit.httpCacheMeta!.lastValidatedAt, now);
    });

    test('a background 200 replaces the bytes', () async {
      await resolver.resolve(request(RevalidationPolicy.staleWhileRevalidate));
      answer.complete(
        http.Response.bytes([2, 2, 2], 200, headers: {'etag': '"v2"'}),
      );
      await pumpEventQueue();

      final hit = (await cache.readRich(key))!;
      expect(hit.bytes, [2, 2, 2]);
      expect(hit.httpCacheMeta!.etag, '"v2"');
    });

    test('a failed background refresh keeps the stale bytes quietly', () async {
      final result = await resolver.resolve(
        request(RevalidationPolicy.staleWhileRevalidate),
      );
      answer.complete(http.Response('down', 500));
      await pumpEventQueue();

      expect(result, old);
      expect(await cache.read(key), old);
    });

    test('immutable never revalidates', () async {
      final result = await resolver.resolveRich(
        request(RevalidationPolicy.immutable),
      );
      await pumpEventQueue();

      expect(result.bytes, old);
      expect(result.origin, BytesOrigin.cache);
      expect(sent, isEmpty);
    });

    test(
      'the default follows HTTP freshness and waits for the answer',
      () async {
        final pending = resolver.resolve(
          const BytesRequest(url: url, cacheKey: key),
        );
        await pumpEventQueue();
        expect(sent, hasLength(1));
        answer.complete(http.Response.bytes([3], 200));
        expect(await pending, [3]);
      },
    );
  });
}
