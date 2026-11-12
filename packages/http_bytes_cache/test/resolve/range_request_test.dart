import 'dart:async';
import 'dart:typed_data';

import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:test/test.dart';

import '../support/range_server.dart';

/// Streaming bodies and single-range GETs against a local server.
void main() {
  group('Range requests', () {
    late RangeServer server;
    late HttpBytesClient client;
    final body = patternBytes(10000);

    setUp(() async {
      server = await RangeServer.start(body);
      client = HttpBytesClient();
    });

    tearDown(() async {
      await client.close();
      await server.close();
    });

    Future<Uint8List> collect(HttpBytesResponse response) =>
        response.stream.toBytes();

    group('HttpBytesClient.stream', () {
      test('206 carries the asked range and its Content-Range', () async {
        final response = await client.stream(
          server.url(),
          range: const ByteRange(100, 200),
        );

        expect(response.statusCode, 206);
        expect(response.isPartial, isTrue);
        expect(response.contentRange, const ContentRange(100, 200, 10000));
        expect(response.totalLength, 10000);
        expect(response.acceptsRanges, isTrue);
        expect(await collect(response), body.sublist(100, 200));
        expect(server.requests.single.start, 100);
        expect(server.requests.single.end, 199);
      });

      test('an open range runs to the end of the representation', () async {
        final response = await client.stream(
          server.url(),
          range: const ByteRange(9990),
        );

        expect(response.contentRange, const ContentRange(9990, 10000, 10000));
        expect(await collect(response), body.sublist(9990));
        expect(server.requests.single.end, isNull);
      });

      test('200 to a range request is the whole body, not partial', () async {
        server.honourRanges = false;

        final response = await client.stream(
          server.url(),
          range: const ByteRange(100, 200),
        );

        expect(response.statusCode, 200);
        expect(response.isPartial, isFalse);
        expect(response.contentRange, isNull);
        expect(response.totalLength, 10000);
        expect(await collect(response), body);
      });

      test('416 fails as a request error carrying the total length', () async {
        await expectLater(
          client.stream(server.url(), range: const ByteRange(20000, 20100)),
          throwsA(
            isA<HttpBytesException$Request>()
                .having((e) => e.statusCode, 'statusCode', 416)
                .having((e) => e.code, 'code', 'range_not_satisfiable'),
          ),
        );
      });

      test('missing Accept-Ranges is reported', () async {
        server.advertiseRanges = false;

        final response = await client.stream(server.url());

        expect(response.acceptsRanges, isFalse);
        expect(response.statusCode, 200);
        expect(await collect(response), body);
      });

      test('a streamed GET is never coalesced with another', () async {
        final a = await client.stream(
          server.url(),
          range: const ByteRange(0, 10),
        );
        final b = await client.stream(
          server.url(),
          range: const ByteRange(0, 10),
        );

        expect(await collect(a), body.sublist(0, 10));
        expect(await collect(b), body.sublist(0, 10));
        expect(server.requests, hasLength(2));
      });

      test('holds its slot until the body is consumed', () async {
        final narrow = HttpBytesClient(maxConcurrent: 1);
        addTearDown(narrow.close);
        final first = await narrow.stream(
          server.url(),
          range: const ByteRange(0, 10),
        );

        var secondStarted = false;
        final second = narrow
            .stream(server.url(), range: const ByteRange(10, 20))
            .then((r) {
              secondStarted = true;
              return r;
            });
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(secondStarted, isFalse);

        expect(await collect(first), body.sublist(0, 10));
        expect(await collect(await second), body.sublist(10, 20));
      });

      test('cancelling the body subscription frees the slot', () async {
        final narrow = HttpBytesClient(maxConcurrent: 1);
        addTearDown(narrow.close);
        final first = await narrow.stream(server.url());
        final subscription = first.stream.listen((_) {});
        await subscription.cancel();

        final second = await narrow
            .stream(server.url(), range: const ByteRange(0, 5))
            .timeout(const Duration(seconds: 2));
        expect(await collect(second), body.sublist(0, 5));
      });

      test('a caller cancel before headers surfaces as cancelled', () async {
        server.stallAt = 50;
        final token = CancelToken();

        final pending = client.stream(
          server.url(),
          range: const ByteRange(50, 60),
          cancelToken: token,
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        token.cancel();

        await expectLater(
          pending,
          throwsA(isA<HttpBytesException$Cancelled>()),
        );
      });
    });

    group('HttpBytesConditionalMiddleware on range GETs', () {
      late HttpBytesClient conditional;

      setUp(() {
        conditional = HttpBytesClient(
          middlewares: <HttpBytesMiddleware>[
            const HttpBytesConditionalMiddleware(),
          ],
        );
      });

      tearDown(() => conditional.close());

      test('sends If-Range with a strong ETag and no If-None-Match', () async {
        final response = await conditional.stream(
          server.url(),
          range: const ByteRange(0, 10),
          context: HttpBytesContext({HttpBytesContext.etagKey: '"v1"'}),
        );
        await collect(response);

        expect(server.requests.single.ifRange, '"v1"');
        expect(server.requests.single.ifNoneMatch, isNull);
        expect(response.statusCode, 206);
      });

      test('a changed representation answers 200 to If-Range', () async {
        server.etag = '"v2"';

        final response = await conditional.stream(
          server.url(),
          range: const ByteRange(0, 10),
          context: HttpBytesContext({HttpBytesContext.etagKey: '"v1"'}),
        );

        expect(response.statusCode, 200);
        expect(response.headers['etag'], '"v2"');
        expect(await collect(response), body);
      });

      test('never sends a weak ETag in If-Range', () async {
        final response = await conditional.stream(
          server.url(),
          range: const ByteRange(0, 10),
          context: HttpBytesContext({HttpBytesContext.etagKey: 'W/"v1"'}),
        );
        await collect(response);

        expect(server.requests.single.ifRange, isNull);
        expect(server.requests.single.ifNoneMatch, isNull);
      });

      test('full GETs keep If-None-Match', () async {
        final response = await conditional.stream(
          server.url(),
          context: HttpBytesContext({HttpBytesContext.etagKey: '"v1"'}),
        );
        await collect(response);

        expect(server.requests.single.ifNoneMatch, '"v1"');
        expect(server.requests.single.ifRange, isNull);
      });
    });

    group('ContentRange.parse', () {
      test('reads a satisfied range with and without a known length', () {
        expect(
          ContentRange.parse('bytes 0-99/1000'),
          const ContentRange(0, 100, 1000),
        );
        expect(ContentRange.parse('bytes 5-9/*'), const ContentRange(5, 10));
      });

      test('reads the unsatisfied form and rejects junk', () {
        expect(ContentRange.parse('bytes */1000'), isNull);
        expect(ContentRange.unsatisfiedLength('bytes */1000'), 1000);
        expect(ContentRange.parse('items 0-1/2'), isNull);
        expect(ContentRange.parse('bytes 9-5/10'), isNull);
      });
    });
  });
}
