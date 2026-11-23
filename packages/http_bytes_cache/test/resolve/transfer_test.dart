import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:test/test.dart';

import '../support/range_server.dart';

/// File-bound GETs whose body stays on the transfer worker.
void main() {
  group('HttpBytesClient.transfer', () {
    final body = patternBytes(100000);
    late RangeServer server;
    late Directory dir;
    late List<HttpBytesTransferRecord> records;
    late HttpBytesClient client;

    HttpBytesClient transferring({int maxConcurrent = 6}) => HttpBytesClient(
      maxConcurrent: maxConcurrent,
      transfers: HttpBytesTransfers(
        landBytes: 16 * 1024,
        onTransfer: records.add,
      ),
    );

    setUp(() async {
      server = await RangeServer.start(body);
      dir = Directory.systemTemp.createTempSync('http_bytes_transfer_');
      records = [];
      client = transferring();
    });

    tearDown(() async {
      await client.close();
      await server.close();
      dir.deleteSync(recursive: true);
    });

    test('is offered only by a client given transfers', () {
      expect(client.canTransfer, isTrue);
      expect(HttpBytesClient().canTransfer, isFalse);
    });

    test('writes the body into the file and reports each span, in order, '
        'once it is there', () async {
      final path = '${dir.path}/body';
      final transfer = await client.transfer(server.url());
      final spans = <(int, int)>[];

      await transfer.writeTo(
        path,
        offset: 0,
        onLanded: (start, end) {
          // Each span is in the file when it is reported.
          final file = File(path).readAsBytesSync();
          expect(file.sublist(start, end), body.sublist(start, end));
          spans.add((start, end));
        },
      );

      expect(transfer.head.statusCode, 200);
      expect(transfer.head.totalLength, body.length);
      expect(File(path).readAsBytesSync(), body);
      expect(spans.length, greaterThan(1));
      expect(spans.first.$1, 0);
      expect(spans.last.$2, body.length);
      for (var i = 1; i < spans.length; i++) {
        expect(spans[i].$1, spans[i - 1].$2);
      }
    });

    test('lands a range at its offset, leaving the rest of the file', () async {
      final path = '${dir.path}/sparse';
      File(path).writeAsBytesSync(Uint8List(8000));
      final transfer = await client.transfer(
        server.url(),
        range: const ByteRange(1000, 5000),
      );

      await transfer.writeTo(path, offset: 1000, onLanded: (_, _) {});

      final file = File(path).readAsBytesSync();
      expect(transfer.head.statusCode, 206);
      expect(transfer.head.contentRange?.start, 1000);
      expect(file.sublist(1000, 5000), body.sublist(1000, 5000));
      expect(file.sublist(0, 1000), everyElement(0));
      expect(file.sublist(5000), everyElement(0));
      expect(server.rangeStarts, [1000]);
    });

    test('a refused answer fails with its status and writes nothing', () async {
      await expectLater(
        client.transfer(server.url(), range: ByteRange(body.length + 10)),
        throwsA(
          isA<HttpBytesException$Request>().having(
            (e) => e.statusCode,
            'statusCode',
            416,
          ),
        ),
      );
    });

    test('a cancelled transfer gives its slot back', () async {
      final single = transferring(maxConcurrent: 1);
      addTearDown(single.close);

      final first = await single.transfer(server.url());
      first.cancel();
      final second = await single
          .transfer(server.url())
          .timeout(const Duration(seconds: 5));
      await second.writeTo(
        '${dir.path}/second',
        offset: 0,
        onLanded: (_, _) {},
      );

      expect(File('${dir.path}/second').lengthSync(), body.length);
    });

    test('the caller cancelling after the head fails the body as '
        'cancelled', () async {
      final token = CancelToken();
      final transfer = await client.transfer(server.url(), cancelToken: token);

      token.cancel();

      await expectLater(
        transfer.writeTo(
          '${dir.path}/cancelled',
          offset: 0,
          onLanded: (_, _) {},
        ),
        throwsA(isA<HttpBytesException$Cancelled>()),
      );
    });

    test(
      'a transfer cancelled before anyone writes it leaves no error behind',
      () async {
        // A preload that is cancelled between its head and its write: nobody
        // awaits the body yet, and its failure must not surface as an
        // uncaught error of the zone.
        final uncaught = <Object>[];
        await runZonedGuarded(() async {
          final token = CancelToken();
          await client.transfer(server.url(), cancelToken: token);
          token.cancel();
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }, (error, stackTrace) => uncaught.add(error));

        expect(uncaught, isEmpty);
      },
    );

    test(
      'a transfer cancelled while it is written leaves no error behind',
      () async {
        final uncaught = <Object>[];
        await runZonedGuarded(() async {
          final token = CancelToken();
          final transfer = await client.transfer(
            server.url(),
            cancelToken: token,
          );
          final write = transfer.writeTo(
            '${dir.path}/exp',
            offset: 0,
            onLanded: (_, _) async {
              await Future<void>.delayed(const Duration(milliseconds: 50));
            },
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));
          token.cancel();
          try {
            await write;
          } on Object catch (_) {}
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }, (error, stackTrace) => uncaught.add(error));
        expect(uncaught, isEmpty);
      },
    );

    test('a span report that throws fails the body with its error', () async {
      final transfer = await client.transfer(server.url());

      await expectLater(
        transfer.writeTo(
          '${dir.path}/thrown',
          offset: 0,
          onLanded: (_, _) => throw StateError('the store refused'),
        ),
        throwsStateError,
      );
    });

    test('tells the host about every transfer when it ends', () async {
      final transfer = await client.transfer(
        server.url(),
        range: const ByteRange(0, 4000),
      );
      await transfer.writeTo(
        '${dir.path}/told',
        offset: 0,
        onLanded: (_, _) {},
      );

      final record = records.single;
      expect(record.url, server.url());
      expect(record.range, 'bytes=0-3999');
      expect(record.statusCode, 206);
      expect(record.bytes, 4000);
      expect(record.failed, isFalse);
      expect(record.head, isNotNull);
    });

    test('a client without a worker refuses to transfer', () async {
      final plain = HttpBytesClient();
      addTearDown(plain.close);

      expect(() => plain.transfer(server.url()), throwsUnsupportedError);
    });
  });
}
