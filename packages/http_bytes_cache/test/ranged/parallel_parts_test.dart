import 'dart:async';

import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:http_bytes_cache/testing.dart';
import 'package:test/test.dart';

import '../support/range_server.dart';

/// A ranged resource downloads in parts, several at once: parts land in any
/// order at their offsets, readers see bytes only once they run unbroken,
/// and a cancelled ask keeps what landed.
void main() {
  group('Parallel parts', () {
    const key = BytesCacheKey('clip');
    final body = patternBytes(40000);

    late RangeServer server;
    late IndexedBytesCache store;
    late HttpBytesClient client;

    setUp(() async {
      server = await RangeServer.start(body);
      store = IndexedBytesCache(
        index: FakeBytesIndex(),
        blobs: FakeBytesBlobStore(),
      );
      client = HttpBytesClient();
    });

    tearDown(() async {
      await client.close();
      await store.close();
      await server.close();
    });

    Future<RangedResource> open(RangedBytes ranged) async {
      addTearDown(ranged.close);
      return ranged.open(RangedRequest(url: server.url(), cacheKey: key));
    }

    RangedBytes parted({int perResource = 4}) => RangedBytes(
      store: store,
      client: client,
      parts: RangedParts(
        partBytes: 4000,
        minPartBytes: 1000,
        perResource: perResource,
      ),
    );

    test('a whole file goes out as several parts at once', () async {
      server.delay = const Duration(milliseconds: 30);
      final resource = await open(parted());

      await resource.ensure(const ByteRange(0));

      expect(server.peakInFlight, 4);
      expect(server.requests.length, 10);
      expect(
        await resource.read(const ByteRange(0, 40000)),
        body,
      );
    });

    test(
      'parts land out of order; a reader waits for unbroken bytes',
      () async {
        final first = Completer<void>();
        server.holds[0] = first.future;
        final resource = await open(parted());
        final landed = <int>[];
        final events = resource.events.listen((event) {
          if (event case RangeLanded(:final range)) landed.add(range.start);
        });
        addTearDown(events.cancel);

        var read = false;
        final reading = resource
            .read(const ByteRange(0, 16000))
            .whenComplete(() => read = true);
        await until(() => resource.ranges.covers(4000, 16000));

        expect(read, isFalse);
        expect(resource.ranges.covers(0, 1), isFalse);
        expect(landed, isNot(contains(0)));

        first.complete();
        expect(await reading, body.sublist(0, 16000));
        expect(landed.last, 0);
      },
    );

    test('a slow part does not hold back the parts after it', () async {
      server.holds[0] = Completer<void>().future;
      final resource = await open(parted(perResource: 2));

      resource.ensure(const ByteRange(0, 20000)).ignore();
      await until(() => resource.ranges.covers(4000, 20000));

      expect(resource.ranges.covers(0, 1), isFalse);
      expect(server.rangeStarts, [0, 4000, 8000, 12000, 16000]);
    });

    test('a cancelled ask keeps the parts that landed', () async {
      final first = Completer<void>();
      server.holds[0] = first.future;
      final resource = await open(parted());
      final token = CancelToken();

      final pending = resource.ensure(
        const ByteRange(0, 16000),
        cancelToken: token,
      );
      await until(() => resource.ranges.covers(4000, 16000));
      token.cancel();
      await expectLater(pending, throwsA(isA<HttpBytesException$Cancelled>()));
      first.complete();
      server.requests.clear();

      await resource.ensure(const ByteRange(0, 16000));

      expect(server.rangeStarts, [0]);
      expect(
        await resource.read(const ByteRange(0, 16000)),
        body.sublist(0, 16000),
      );
    });

    test('parts per resource and in total stay within their limits', () async {
      server.delay = const Duration(milliseconds: 30);
      final resource = await open(parted(perResource: 2));

      await resource.ensure(const ByteRange(0, 40000));
      expect(server.peakInFlight, 2);

      final capped = HttpBytesClient(maxConcurrent: 3);
      addTearDown(capped.close);
      final shared = RangedBytes(
        store: store,
        client: capped,
        parts: const RangedParts(partBytes: 4000, minPartBytes: 1000),
      );
      addTearDown(shared.close);
      server.peakInFlight = 0;
      final a = await shared.open(
        RangedRequest(url: server.url(), cacheKey: const BytesCacheKey('a')),
      );
      final b = await shared.open(
        RangedRequest(url: server.url(), cacheKey: const BytesCacheKey('b')),
      );
      await Future.wait([
        a.ensure(const ByteRange(0, 40000)),
        b.ensure(const ByteRange(0, 40000)),
      ]);
      expect(server.peakInFlight, 3);
    });

    test('a 200 to one part replaces the representation; the other parts '
        'stop and record nothing', () async {
      final conditional = HttpBytesClient(
        middlewares: <HttpBytesMiddleware>[
          const HttpBytesConditionalMiddleware(),
        ],
      );
      addTearDown(conditional.close);
      final resource = await open(
        RangedBytes(
          store: store,
          client: conditional,
          parts: const RangedParts(partBytes: 4000, minPartBytes: 1000),
        ),
      );
      await resource.ensure(const ByteRange(0, 4000));
      final changed = patternBytes(40000, seed: 7);
      server
        ..body = changed
        ..etag = '"v2"'
        ..delay = const Duration(milliseconds: 20);

      await resource.ensure(const ByteRange(0));

      expect(await resource.read(const ByteRange(0, 40000)), changed);
    });

    test('bytes a reader needs now go before parts read ahead', () async {
      server.delay = const Duration(milliseconds: 20);
      final single = HttpBytesClient(maxConcurrent: 1);
      addTearDown(single.close);
      final serial = RangedBytes(
        store: store,
        client: single,
        parts: const RangedParts(partBytes: 4000, minPartBytes: 1000),
      );
      addTearDown(serial.close);
      final ahead = await serial.open(
        RangedRequest(
          url: server.url('/a'),
          cacheKey: const BytesCacheKey('a'),
        ),
      );
      final now = await serial.open(
        RangedRequest(
          url: server.url('/b'),
          cacheKey: const BytesCacheKey('b'),
        ),
      );

      final whole = ahead.ensure(const ByteRange(0, 16000));
      await until(() => server.requests.isNotEmpty);
      await now.ensure(const ByteRange(20000, 21000));
      await whole;

      // a's first part was already out; its parts ahead waited for b's.
      expect(server.rangeStarts.take(2), [0, 20000]);
    });
  });
}

/// Waits until [condition] holds, polling.
Future<void> until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition never held');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
