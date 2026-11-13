import 'dart:async';
import 'dart:typed_data';

import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:http_bytes_cache/testing.dart';
import 'package:test/test.dart';

import '../support/range_server.dart';

/// Fetching ranged resources into the store against a local server.
void main() {
  group('RangedResource', () {
    const key = BytesCacheKey('video');
    final body = patternBytes(10000);

    late RangeServer server;
    late IndexedBytesCache store;
    late HttpBytesClient client;
    late RangedBytes ranged;

    setUp(() async {
      server = await RangeServer.start(body);
      store = IndexedBytesCache(
        index: FakeBytesIndex(),
        blobs: FakeBytesBlobStore(),
      );
      client = HttpBytesClient(
        middlewares: <HttpBytesMiddleware>[
          const HttpBytesConditionalMiddleware(),
        ],
      );
      ranged = RangedBytes(store: store, client: client, chunkBytes: 1000);
    });

    tearDown(() async {
      await ranged.close();
      await client.close();
      await store.close();
      await server.close();
    });

    Future<RangedResource> open() =>
        ranged.open(RangedRequest(url: server.url(), cacheKey: key));

    test('fetches a missing range in chunks and lands it', () async {
      final resource = await open();
      final landed = <ByteRange>[];
      final events = resource.events.listen((event) {
        if (event case RangeLanded(:final range)) landed.add(range);
      });
      addTearDown(events.cancel);

      await resource.ensure(const ByteRange(100, 1500));

      expect(server.rangeStarts, [100, 1100]);
      expect(resource.totalLength, 10000);
      expect(resource.ranges.covers(100, 1500), isTrue);
      expect(landed, isNotEmpty);
      expect(
        await resource.read(const ByteRange(100, 1500)),
        body.sublist(100, 1500),
      );
    });

    test('present bytes are never fetched again', () async {
      final resource = await open();
      await resource.ensure(const ByteRange(0, 500));
      await resource.ensure(const ByteRange(200, 400));

      expect(server.requests, hasLength(1));
    });

    test('only the gap between present spans is fetched', () async {
      final resource = await open();
      await resource.ensure(const ByteRange(0, 1000));
      await resource.ensure(const ByteRange(1500, 2500));
      server.requests.clear();

      await resource.ensure(const ByteRange(500, 2000));

      expect(server.requests.single.start, 1000);
      expect(server.requests.single.end, 1499);
    });

    test('concurrent asks for the same bytes share one GET', () async {
      final resource = await open();

      await Future.wait([
        resource.ensure(const ByteRange(0, 300)),
        resource.ensure(const ByteRange(100, 600)),
      ]);

      expect(server.requests, hasLength(1));
    });

    test('an open range runs to the end of the representation', () async {
      final resource = await open();

      await resource.ensure(const ByteRange(9500));

      expect(resource.ranges.covers(9500, 10000), isTrue);
      expect(
        await resource.read(const ByteRange(9500, 10000)),
        body.sublist(9500),
      );
    });

    test('a range past the end is already satisfied', () async {
      final resource = await open();
      await resource.ensure(const ByteRange(0, 10));

      await resource.ensure(const ByteRange(20000, 20100));

      expect(server.requests, hasLength(1));
    });

    test(
      'a 200 to a range GET drops every span and keeps the new body',
      () async {
        final resource = await open();
        await resource.ensure(const ByteRange(0, 500));
        final resets = <RangedEvent>[];
        final events = resource.events.listen((event) {
          if (event is RangesReset) resets.add(event);
        });
        addTearDown(events.cancel);

        final changed = patternBytes(10000).reversed.toList();
        server
          ..body = Uint8List.fromList(changed)
          ..etag = '"v2"';
        await resource.ensure(const ByteRange(2000, 2100));

        expect(server.requests.last.ifRange, '"v1"');
        expect(resets, hasLength(1));
        expect(resource.ranges.covers(0, 10000), isTrue);
        expect(
          await resource.read(const ByteRange(0, 500)),
          changed.sublist(0, 500),
        );
      },
    );

    test('a server without range support is read sequentially', () async {
      server
        ..honourRanges = false
        ..advertiseRanges = false;
      final resource = await open();

      await resource.ensure(const ByteRange(5000, 5100));
      await resource.ensure(const ByteRange(8000, 8100));

      expect(resource.sequentialOnly, isTrue);
      expect(server.requests, hasLength(1));
      expect(resource.ranges.covers(0, 10000), isTrue);
    });

    test('cancelling an ask while its bytes are pending', () async {
      server.stallAt = 3000;
      final resource = await open();
      final token = CancelToken();

      final pending = resource.ensure(
        const ByteRange(3000, 3100),
        cancelToken: token,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      token.cancel();

      await expectLater(pending, throwsA(isA<HttpBytesException$Cancelled>()));
    });

    test('a cancel token holds one wait at a time, however many GETs and '
        'landings the ask waits through', () async {
      final fine = RangedBytes(
        store: store,
        client: client,
        chunkBytes: 100,
        writeBytes: 100,
      );
      addTearDown(fine.close);
      final resource = await fine.open(
        RangedRequest(url: server.url(), cacheKey: key),
      );
      final token = CancelToken();
      final held = <int>[];
      final events = resource.events.listen((event) {
        if (event is RangeLanded) held.add(token.debugLinkedCount);
      });
      addTearDown(events.cancel);

      await resource.ensure(const ByteRange(0, 10000), cancelToken: token);

      expect(held.length, greaterThan(10));
      expect(held, everyElement(lessThanOrEqualTo(1)));
      expect(held, contains(1));
      expect(token.debugLinkedCount, 0);
    });

    test('a store that cannot keep ranges is reported unsupported', () async {
      final unsupported = RangedBytes(
        store: MemoryBytesCache(),
        client: client,
      );

      expect(unsupported.isSupported, isFalse);
      await expectLater(
        unsupported.open(RangedRequest(url: server.url(), cacheKey: key)),
        throwsUnsupportedError,
      );
    });
  });
}
