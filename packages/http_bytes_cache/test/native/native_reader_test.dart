import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:http_bytes_cache/native_reader.dart';
import 'package:test/test.dart';

import '../support/range_server.dart';

/// The C reader driven through FFI. Reads block, so they run on helper
/// isolates (as a player's reads run on its own threads) while this isolate
/// fetches and signals landings.
void main() {
  group('Native reader', () {
    const key = BytesCacheKey('native-video');
    final body = patternBytes(10000);

    late Directory dir;
    late RangeServer server;
    late IRangedBytesStore store;
    late HttpBytesClient client;
    late RangedBytes ranged;
    late NativeRangedReaders readers;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('native_reader_');
      server = await RangeServer.start(body);
      store =
          await BytesCache.open(directory: dir.path, throwOnOpenFailure: true)
              as IRangedBytesStore;
      client = HttpBytesClient();
      ranged = RangedBytes(store: store, client: client, chunkBytes: 1000);
      readers = NativeRangedReaders(ranged, readAheadBytes: 1000);
    });

    tearDown(() async {
      await readers.close();
      await ranged.close();
      await client.close();
      await store.close();
      await server.close();
      await dir.delete(recursive: true);
    });

    Future<NativePublication> publish([Uri? url]) => readers.publish(
      RangedRequest(url: url ?? server.url(), cacheKey: key),
    );

    Future<Object> readElsewhere(int offset, int length) =>
        _readElsewhere(key.value, offset, length);

    test('is built for this host', () {
      expect(NativeRangedReaders.isAvailable, isTrue);
      expect(NativeRangedReaders.apiAddress, isNot(0));
    });

    test('a key nobody published opens no reader', () {
      expect(NativeRangedReader.open(const BytesCacheKey('nothing')), isNull);
    });

    test('hit: present bytes read at once, with no fetch', () async {
      final publication = await publish();
      await publication.resource.ensure(const ByteRange(0, 2000));
      final requests = server.requests.length;

      final bytes = await readElsewhere(100, 500);

      expect(bytes, body.sublist(100, 600));
      expect(server.requests, hasLength(requests));
    });

    test('miss: the read asks Dart, blocks, and wakes when the range '
        'lands', () async {
      await publish();

      final bytes = await readElsewhere(5000, 100);

      expect(bytes, body.sublist(5000, 5100));
      expect(server.rangeStarts, contains(5000));
    });

    test('a read at the end returns nothing', () async {
      await publish();

      expect(await readElsewhere(9990, 100), body.sublist(9990));
      expect(await readElsewhere(10000, 100), isEmpty);
    });

    test('length waits until a response tells it', () async {
      await publish();
      final name = key.value;

      final length = await _waitedLengthElsewhere(name);

      expect(length, 10000);
    });

    test('cancel wakes a read blocked on a range that never lands', () async {
      server.stallAt = 7000;
      await publish();
      final replies = ReceivePort();
      addTearDown(replies.close);
      final messages = StreamIterator(replies);

      await Isolate.spawn(_blockedRead, (replies.sendPort, key.value, 7000));
      expect(await messages.moveNext(), isTrue);
      final address = messages.current as int;
      while (!server.rangeStarts.contains(7000)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      NativeRangedReader.cancelAt(address);

      expect(await messages.moveNext(), isTrue);
      expect(messages.current, -1);
    });

    test('a failed fetch fails the blocked read', () async {
      await publish(Uri.parse('http://127.0.0.1:1/unreachable.mp4'));

      expect(await readElsewhere(0, 10), -2);
    });

    test('unpublishing wakes blocked reads as closed', () async {
      server.stallAt = 3000;
      final publication = await publish();
      final replies = ReceivePort();
      addTearDown(replies.close);
      final messages = StreamIterator(replies);

      await Isolate.spawn(_blockedRead, (replies.sendPort, key.value, 3000));
      expect(await messages.moveNext(), isTrue);
      while (!server.rangeStarts.contains(3000)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      await publication.close();

      expect(await messages.moveNext(), isTrue);
      expect(messages.current, -3);
    });
  });
}

// Isolate entry points stay top level: a closure inside a test would
// capture the test's context, server and store included, which cannot be
// sent to another isolate.

/// Reads on a helper isolate; the bytes, or the error code.
Future<Object> _readElsewhere(String key, int offset, int length) =>
    Isolate.run(() {
      final reader = NativeRangedReader.open(BytesCacheKey(key))!;
      try {
        return reader.read(offset, length);
      } on NativeReadException catch (error) {
        return error.code;
      } finally {
        reader.close();
      }
    });

/// The length a reader on [key] waits for, on a helper isolate.
Future<int> _waitedLengthElsewhere(String key) => Isolate.run(() {
  final reader = NativeRangedReader.open(BytesCacheKey(key))!;
  try {
    return reader.length(wait: true);
  } finally {
    reader.close();
  }
});

/// Opens a reader on `key`, sends its address, blocks reading at `offset`,
/// then sends the error code (or the byte count).
void _blockedRead((SendPort, String, int) message) {
  final (replies, key, offset) = message;
  final reader = NativeRangedReader.open(BytesCacheKey(key))!;
  replies.send(reader.address);
  try {
    replies.send(reader.read(offset, 10).length);
  } on NativeReadException catch (error) {
    replies.send(error.code);
  } finally {
    reader.close();
  }
}
