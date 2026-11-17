import 'dart:typed_data';

import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:http_bytes_cache/testing.dart';
import 'package:test/test.dart';

import '../support/range_server.dart';

/// Fast start over progressive MP4: the head, then `moov` wherever it is.
void main() {
  group('Fast start', () {
    const key = BytesCacheKey('clip');
    const headBytes = 8 * 1024;

    /// One top-level box: 32-bit size, four-character type, [payload] bytes
    /// filled with [fill].
    Uint8List box(String type, int payload, {int fill = 0}) {
      final bytes = Uint8List(8 + payload)
        ..buffer.asByteData().setUint32(0, 8 + payload)
        ..setAll(4, type.codeUnits);
      for (var i = 8; i < bytes.length; i++) {
        bytes[i] = fill;
      }
      return bytes;
    }

    Uint8List file(List<Uint8List> boxes) =>
        Uint8List.fromList([for (final b in boxes) ...b]);

    final ftyp = box('ftyp', 16, fill: 1);
    final moov = box('moov', 3000, fill: 2);
    final mdat = box('mdat', 200000, fill: 3);

    late RangeServer server;
    late IndexedBytesCache store;
    late HttpBytesClient client;
    late RangedBytes ranged;

    Future<void> serve(Uint8List body) async {
      server = await RangeServer.start(body);
      store = IndexedBytesCache(
        index: FakeBytesIndex(),
        blobs: FakeBytesBlobStore(),
      );
      client = HttpBytesClient();
      ranged = RangedBytes(
        store: store,
        client: client,
        parts: const RangedParts(partBytes: 4096),
      );
    }

    tearDown(() async {
      await ranged.close();
      await client.close();
      await store.close();
      await server.close();
    });

    Future<RangedResource> open() =>
        ranged.open(RangedRequest(url: server.url(), cacheKey: key));

    test('moov first: the head holds it and nothing else is fetched', () async {
      await serve(file([ftyp, moov, mdat]));
      final resource = await open();

      final start = await resource.fastStart(headBytes: headBytes);

      final moovStart = ftyp.length;
      expect(start?.moovStart, moovStart);
      expect(start?.moovEnd, moovStart + moov.length);
      expect(start?.moovAtEnd, isFalse);
      expect(resource.ranges.covers(0, headBytes), isTrue);
      expect(server.requests.every((r) => r.start! < headBytes), isTrue);
      expect(resource.ranges.covers(100000, 100001), isFalse);
    });

    test('moov last: the head, then the tail, never the middle', () async {
      await serve(file([ftyp, mdat, moov]));
      final resource = await open();

      final start = await resource.fastStart(headBytes: headBytes);

      final moovStart = ftyp.length + mdat.length;
      expect(start?.moovStart, moovStart);
      expect(start?.moovEnd, moovStart + moov.length);
      expect(start?.moovAtEnd, isTrue);
      expect(resource.ranges.covers(0, headBytes), isTrue);
      expect(
        resource.ranges.covers(moovStart, moovStart + moov.length),
        isTrue,
      );
      expect(resource.ranges.covers(100000, 100001), isFalse);
      expect(server.requests.map((r) => r.start), contains(moovStart));
      expect(
        await resource.read(ByteRange(moovStart, moovStart + 8)),
        moov.sublist(0, 8),
      );
    });

    test(
      'a body that is not MP4 has no moov; the head is still held',
      () async {
        await serve(patternBytes(20000));
        final resource = await open();

        final start = await resource.fastStart(headBytes: headBytes);

        expect(start, isNull);
        expect(resource.ranges.covers(0, headBytes), isTrue);
      },
    );

    test('every open of a key shares one resource and its GETs', () async {
      await serve(file([ftyp, mdat, moov]));
      final inline = await open();
      final fullscreen = await open();

      await Future.wait([
        inline.fastStart(headBytes: headBytes),
        fullscreen.fastStart(headBytes: headBytes),
      ]);
      final requests = server.requests.length;
      await fullscreen.fastStart(headBytes: headBytes);

      expect(server.requests, hasLength(requests));
      expect(inline.ranges, fullscreen.ranges);

      await inline.close();
      expect(fullscreen.ranges.covers(0, headBytes), isTrue);
    });
  });
}
