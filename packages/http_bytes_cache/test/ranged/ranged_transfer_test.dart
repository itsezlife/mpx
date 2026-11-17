import 'dart:io';

import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:test/test.dart';

import '../support/range_server.dart';

/// Ranged resources fetched by transfers: the body goes from the socket to
/// the sparse file on the client's worker; this isolate records the spans.
void main() {
  group('RangedResource over a transfer client', () {
    const key = BytesCacheKey('video');
    final body = patternBytes(300000);

    late RangeServer server;
    late Directory dir;
    late IRangedBytesStore store;
    late HttpBytesClient client;
    late RangedBytes ranged;
    late List<HttpBytesTransferRecord> transfers;

    setUp(() async {
      server = await RangeServer.start(body);
      dir = Directory.systemTemp.createTempSync('ranged_transfer_');
      store =
          await BytesCache.open(directory: dir.path, throwOnOpenFailure: true)
              as IRangedBytesStore;
      transfers = [];
      client = HttpBytesClient(
        middlewares: <HttpBytesMiddleware>[
          const HttpBytesConditionalMiddleware(),
        ],
        transfers: HttpBytesTransfers(
          landBytes: 16 * 1024,
          onTransfer: transfers.add,
        ),
      );
      ranged = RangedBytes(
        store: store,
        client: client,
        parts: const RangedParts(partBytes: 50000),
      );
    });

    tearDown(() async {
      await ranged.close();
      await client.close();
      await store.close();
      await server.close();
      dir.deleteSync(recursive: true);
    });

    Future<RangedResource> open() =>
        ranged.open(RangedRequest(url: server.url(), cacheKey: key));

    test('lands a range in chunks, each span announced', () async {
      final resource = await open();
      final landed = <ByteRange>[];
      final events = resource.events.listen((event) {
        if (event case RangeLanded(:final range)) landed.add(range);
      });
      addTearDown(events.cancel);

      await resource.ensure(const ByteRange(1000, 70000));

      expect(server.rangeStarts, [1000, 51000]);
      expect(transfers, isNotEmpty);
      expect(resource.totalLength, body.length);
      expect(resource.ranges.covers(1000, 70000), isTrue);
      expect(landed.length, greaterThan(2));
      expect(
        await resource.read(const ByteRange(1000, 70000)),
        body.sublist(1000, 70000),
      );
    });

    test('an ask to the end goes out in parts written at their offsets, and '
        'the whole body reads back as a whole resource', () async {
      server.delay = const Duration(milliseconds: 20);
      final resource = await open();

      await resource.ensure(const ByteRange(0));

      expect(server.rangeStarts.first, 0);
      expect(
        server.rangeStarts.toSet(),
        {0, 50000, 100000, 150000, 200000, 250000},
      );
      expect(server.peakInFlight, greaterThan(1));
      expect(resource.ranges.covers(0, body.length), isTrue);
      expect(store.contains(key), isTrue);
      expect(await store.read(key), body);
    });

    test('a server that ignores ranges sends the whole body, kept from the '
        'start', () async {
      server.honourRanges = false;
      final resource = await open();

      await resource.ensure(const ByteRange(5000, 6000));
      // The rest comes on the same GET.
      await resource.ensure(const ByteRange(0));

      expect(server.requests, hasLength(1));
      expect(resource.ranges.covers(0, body.length), isTrue);
      expect(await store.read(key), body);
    });

    test(
      'a native reader of the file sees the bytes the worker wrote',
      () async {
        final resource = await open();

        await resource.ensure(const ByteRange(0, 40000));

        final file = File(resource.path).openSync();
        addTearDown(file.closeSync);
        expect(file.readSync(40000), body.sublist(0, 40000));
      },
    );
  });
}
