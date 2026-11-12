import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:test/test.dart';

void main() {
  group('BytesResolver.peek', () {
    const key = BytesCacheKey('media-1');
    const request = BytesRequest(
      url: 'https://cdn.example.com/m1.webp',
      cacheKey: key,
    );
    late DateTime now;
    late MemoryBytesCache cache;
    late Completer<http.Response> response;
    late BytesResolver resolver;

    setUp(() {
      now = DateTime.utc(2026, 1, 1);
      cache = MemoryBytesCache(
        clock: () => now,
        retention: const BytesRetention.maxAge(Duration(days: 1)),
      );
      response = Completer<http.Response>();
      final client = HttpBytesClient(
        client: MockClient((_) => response.future),
        middlewares: const [],
      );
      addTearDown(client.close);
      resolver = BytesResolver(cache: cache, client: client);
    });

    test('absent when the store has nothing and nothing is in flight', () {
      expect(resolver.peek(request), BytesPeek.absent);
    });

    test('cached when the store holds the bytes', () async {
      await cache.write(key, Uint8List.fromList([1]));
      expect(resolver.peek(request), BytesPeek.cached);
    });

    test('in flight from the moment a resolve starts until it ends', () async {
      final pending = resolver.resolve(request);
      expect(resolver.peek(request), BytesPeek.inFlight);

      response.complete(http.Response.bytes([7, 7], 200));
      await pending;
      await pumpEventQueue();
      expect(resolver.peek(request), BytesPeek.cached);
    });

    test('absent again after a failed resolve', () async {
      final pending = resolver.resolve(request);
      response.complete(http.Response('gone', 404));
      await expectLater(pending, throwsA(isA<HttpBytesException>()));
      expect(resolver.peek(request), BytesPeek.absent);
    });

    test('absent when the cached row is past its age', () async {
      await cache.write(key, Uint8List.fromList([1]));
      now = now.add(const Duration(days: 2));
      expect(resolver.peek(request), BytesPeek.absent);
    });

    test('a request without a cache key peeks by its URL identity', () async {
      const plain = BytesRequest(url: 'https://cdn.example.com/plain.png');
      await cache.write(
        BytesCacheKey.fromUrl(plain.url),
        Uint8List.fromList([1]),
      );
      expect(resolver.peek(plain), BytesPeek.cached);
    });
  });

  group('HttpBytesClient.isInFlight', () {
    test('is true while a GET for the key runs', () async {
      final response = Completer<http.Response>();
      final client = HttpBytesClient(
        client: MockClient((_) => response.future),
        middlewares: const [],
      );
      addTearDown(client.close);
      final url = Uri.parse('https://cdn.example.com/x.bin');
      final key = BytesCacheKey.fromUrl(url.toString());

      expect(client.isInFlight(key), isFalse);
      final pending = client.getBytes(url);
      await pumpEventQueue();
      expect(client.isInFlight(key), isTrue);
      response.complete(http.Response.bytes([1], 200));
      await pending;
      expect(client.isInFlight(key), isFalse);
    });
  });
}
