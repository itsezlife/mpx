import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:http_bytes_cache/testing.dart';
import 'package:test/test.dart';

import '../support/range_server.dart';

/// A ranged open of a key that already holds complete bytes, as a whole
/// row or as an alias of a captured file: the bytes are read where they
/// are, nothing is fetched.
void main() {
  group('Ranged open of complete bytes', () {
    const local = BytesCacheKey('local-uuid');
    const server = BytesCacheKey('server-42');
    final body = patternBytes(5000);

    late RangeServer origin;
    late IndexedBytesCache store;
    late HttpBytesClient client;
    late RangedBytes ranged;

    setUp(() async {
      origin = await RangeServer.start(body);
      store = IndexedBytesCache(
        index: FakeBytesIndex(),
        blobs: FakeBytesBlobStore(),
      );
      client = HttpBytesClient();
      ranged = RangedBytes(store: store, client: client, chunkBytes: 1000);
    });

    tearDown(() async {
      await ranged.close();
      await client.close();
      await store.close();
      await origin.close();
    });

    Future<RangedResource> open(BytesCacheKey key) =>
        ranged.open(RangedRequest(url: origin.url(), cacheKey: key));

    test('a whole row reads as complete, without a request', () async {
      await store.write(server, body);

      final resource = await open(server);
      await resource.ensure(const ByteRange(0, 5000));

      expect(resource.totalLength, 5000);
      expect(resource.ranges.covers(0, 5000), isTrue);
      expect(
        await resource.read(const ByteRange(10, 20)),
        body.sublist(10, 20),
      );
      expect(origin.requests, isEmpty);
    });

    test(
      'an alias of a whole row reads its bytes, without a request',
      () async {
        await store.write(local, body);
        await store.alias(local, server);

        final resource = await open(server);
        await resource.ensure(const ByteRange(0, 5000));

        expect(resource.ranges.covers(0, 5000), isTrue);
        expect(
          await resource.read(const ByteRange(4000, 4100)),
          body.sublist(4000, 4100),
        );
        expect(origin.requests, isEmpty);
        expect(await store.read(local), body);
        expect(await store.read(server), body);
      },
    );

    test('an alias of a complete ranged resource reads its bytes', () async {
      await store.openRanged(local).then((lease) => lease.release());
      await store.writeRange(local, 0, body, totalLength: body.length);
      await store.alias(local, server);

      final resource = await open(server);
      await resource.ensure(const ByteRange(0, 5000));

      expect(await resource.read(const ByteRange(0, 50)), body.sublist(0, 50));
      expect(origin.requests, isEmpty);
    });
  });
}
