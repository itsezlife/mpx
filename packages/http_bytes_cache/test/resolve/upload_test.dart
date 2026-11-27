import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:test/test.dart';

import '../support/upload_server.dart';

/// Request bodies streamed from a file range on the transfer worker.
void main() {
  group('HttpBytesClient.upload', () {
    late UploadServer server;
    late Directory dir;
    late HttpBytesClient client;
    late List<BytesLogEvent> events;
    late BytesDiagnostics previousDiagnostics;

    setUp(() async {
      server = await UploadServer.start();
      dir = Directory.systemTemp.createTempSync('http_bytes_upload_');
      client = HttpBytesClient(
        transfers: const HttpBytesTransfers(landBytes: 64 * 1024),
      );
      events = [];
      previousDiagnostics = BytesDiagnostics.current;
      BytesDiagnostics.current = BytesDiagnostics.onEvent(events.add);
    });

    tearDown(() async {
      BytesDiagnostics.current = previousDiagnostics;
      await client.close();
      await server.close();
      dir.deleteSync(recursive: true);
    });

    List<BytesLogEvent> eventsOf(BytesLogOp op) => [
      for (final event in events)
        if (event.op == op) event,
    ];

    test('sends exactly the range, its first and last byte included, '
        'with the method and headers, and hands back the answer', () async {
      final file = patternFile('${dir.path}/source', 10000);
      server
        ..patternStart = 1000
        ..answer = '{"id":7}'.codeUnits;

      final response = await client.upload(
        server.url(),
        method: 'PUT',
        headers: {'x-upload-part': '3'},
        body: HttpBytesUploadBody.file(file.path, offset: 1000, length: 5000),
      );

      final received = server.received.single;
      final source = file.readAsBytesSync();
      expect(received.method, 'PUT');
      expect(received.headers['x-upload-part'], '3');
      expect(received.headers['content-length'], '5000');
      expect(received.length, 5000);
      expect(received.firstMismatch, isNull);
      final kept = received.kept.toBytes();
      expect(kept.first, source[1000]);
      expect(kept.last, source[5999]);
      expect(kept, source.sublist(1000, 6000));
      expect(response.statusCode, 200);
      expect(response.body, '{"id":7}'.codeUnits);
    });

    test('sends POST, PUT and PATCH, and refuses other methods', () async {
      final file = patternFile('${dir.path}/small', 100);
      for (final method in ['POST', 'PUT', 'PATCH']) {
        await client.upload(
          server.url(),
          method: method,
          body: HttpBytesUploadBody.file(file.path, length: 100),
        );
      }

      expect(
        [for (final r in server.received) r.method],
        [
          'POST',
          'PUT',
          'PATCH',
        ],
      );
      expect(
        () => client.upload(
          server.url(),
          method: 'GET',
          body: HttpBytesUploadBody.file(file.path, length: 100),
        ),
        throwsArgumentError,
      );
    });

    test('a 50 MiB range streams, held back by a stalled receiver, its '
        'progress growing to the length', () async {
      const length = 50 * 1024 * 1024;
      const offset = 3;
      // What a stalled receiver lets the sender get ahead by: the socket
      // buffers and the pipeline in between, far below the range. A range
      // read whole before sending would report all 50 MiB at once.
      const slack = 16 * 1024 * 1024;
      final file = patternFile('${dir.path}/large', length + offset);
      server
        ..keepUpTo = 0
        ..holdAfter = 1024 * 1024;
      final progress = <(int, int?)>[];

      final upload = client.upload(
        server.url(),
        body: HttpBytesUploadBody.file(
          file.path,
          offset: offset,
          length: length,
        ),
        onBytesSent: (sent, total) => progress.add((sent, total)),
      );
      await server.held.future;
      // Long enough for a sender that does not wait to run far ahead.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final aheadWhileStalled =
          progress.last.$1 - server.received.single.length;
      expect(aheadWhileStalled, lessThan(slack));
      expect(progress.last.$1, lessThan(length));

      server.release.complete();
      await upload;

      final received = server.received.single;
      expect(received.length, length);
      expect(received.first, offset % 251);
      expect(received.last, (offset + length - 1) % 251);
      expect(progress.first, (0, length));
      expect(progress.last, (length, length));
      expect(progress.length, greaterThan(10));
      for (var i = 1; i < progress.length; i++) {
        expect(progress[i].$1, greaterThanOrEqualTo(progress[i - 1].$1));
        expect(progress[i].$2, length);
      }
    });

    test('cancelling stops the body', () async {
      const length = 8 * 1024 * 1024;
      final file = patternFile('${dir.path}/cancel', length);
      server
        ..keepUpTo = 0
        ..holdAfter = 256 * 1024;
      final token = CancelToken();

      final upload = client.upload(
        server.url(),
        body: HttpBytesUploadBody.file(file.path, length: length),
        cancelToken: token,
      );
      await server.held.future;
      token.cancel();

      await expectLater(upload, throwsA(isA<HttpBytesException$Cancelled>()));
      server.release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final received = server.received.single;
      expect(received.complete, isFalse);
      expect(received.length, lessThan(length));
      expect(eventsOf(BytesLogOp.uploadGaveUp), isEmpty);
    });

    test('a body that goes the receive timeout without progress fails as a '
        'timeout', () async {
      final slow = HttpBytesClient(
        transfers: const HttpBytesTransfers(
          receiveTimeout: Duration(milliseconds: 300),
        ),
      );
      addTearDown(slow.close);
      final file = patternFile('${dir.path}/stall', 4 * 1024 * 1024);
      server
        ..keepUpTo = 0
        ..holdAfter = 1;
      addTearDown(() {
        if (!server.release.isCompleted) server.release.complete();
      });

      await expectLater(
        slow.upload(
          server.url(),
          body: HttpBytesUploadBody.file(file.path, length: 4 * 1024 * 1024),
        ),
        throwsA(isA<HttpBytesException$Timeout>()),
      );
    });

    test('a range past the end of the file, or a missing file, fails '
        'before anything is sent', () async {
      final file = patternFile('${dir.path}/short', 100);

      await expectLater(
        client.upload(
          server.url(),
          body: HttpBytesUploadBody.file(file.path, offset: 50, length: 51),
        ),
        throwsA(
          isA<HttpBytesException$Internal>().having(
            (e) => e.code,
            'code',
            'read_failed',
          ),
        ),
      );
      await expectLater(
        client.upload(
          server.url(),
          body: HttpBytesUploadBody.file('${dir.path}/absent', length: 1),
        ),
        throwsA(isA<HttpBytesException$Internal>()),
      );
      expect(server.received, isEmpty);
    });

    test('a blob body is for the web', () {
      expect(
        () => client.upload(
          server.url(),
          body: const HttpBytesUploadBody.blob(Object(), length: 1),
        ),
        throwsUnsupportedError,
      );
    });

    group('retry', () {
      late File file;
      late List<Duration> waits;

      Future<void> recordWait(Duration delay) async => waits.add(delay);

      setUp(() {
        file = patternFile('${dir.path}/part', 1000);
        waits = [];
      });

      test('the part preset tries a 503 five times in all, waiting 1 s to '
          '30 s between, then fails', () async {
        server.statuses.addAll(List.filled(6, 503));

        await expectLater(
          client.upload(
            server.url(),
            body: HttpBytesUploadBody.file(file.path, length: 1000),
            retry: HttpBytesRetryBackoff.uploadPart,
            retryRandom: math.Random(7),
            retryWait: recordWait,
          ),
          throwsA(
            isA<HttpBytesException$Server>().having(
              (e) => e.statusCode,
              'statusCode',
              503,
            ),
          ),
        );

        expect(server.received, hasLength(5));
        expect(waits, hasLength(4));
        for (final wait in waits) {
          expect(wait, greaterThanOrEqualTo(const Duration(seconds: 1)));
          expect(wait, lessThanOrEqualTo(const Duration(seconds: 30)));
        }
      });

      test('reports each try, each retry with its attempt and delay, and '
          'the give-up, with no query or headers', () async {
        server.statuses.addAll(List.filled(5, 503));

        await expectLater(
          client.upload(
            server.url(),
            headers: {'authorization': 'Bearer hidden'},
            body: HttpBytesUploadBody.file(file.path, length: 1000),
            retry: HttpBytesRetryBackoff.uploadPart,
            retryRandom: math.Random(7),
            retryWait: recordWait,
          ),
          throwsA(isA<HttpBytesException$Server>()),
        );

        final started = eventsOf(BytesLogOp.uploadStarted);
        expect(
          [for (final e in started) e.fields['attempt']],
          [
            1,
            2,
            3,
            4,
            5,
          ],
        );
        expect(started.first.level, BytesLogLevel.debug);
        expect(started.first.fields['bytes'], 1000);
        expect(started.first.fields['method'], 'POST');
        final retries = eventsOf(BytesLogOp.uploadRetry);
        expect([for (final e in retries) e.fields['attempt']], [1, 2, 3, 4]);
        expect(
          [for (final e in retries) e.fields['delayMs']],
          [
            for (final wait in waits) wait.inMilliseconds,
          ],
        );
        expect(retries.first.level, BytesLogLevel.warning);
        expect(retries.first.fields['status'], 503);
        final gaveUp = eventsOf(BytesLogOp.uploadGaveUp).single;
        expect(gaveUp.level, BytesLogLevel.error);
        expect(gaveUp.fields['attempts'], 5);
        expect(gaveUp.fields['status'], 503);
        for (final event in events) {
          expect(event.message, isNot(contains('secret')));
          expect(event.message, isNot(contains('/upload')));
          expect(event.message, isNot(contains('hidden')));
          expect(event.fields.values, isNot(contains(contains('secret'))));
        }
      });

      test('a try that succeeds after a retry answers', () async {
        server.statuses.addAll([503, 502]);

        final response = await client.upload(
          server.url(),
          body: HttpBytesUploadBody.file(file.path, length: 1000),
          retry: HttpBytesRetryBackoff.uploadPart,
          retryWait: recordWait,
        );

        expect(response.statusCode, 200);
        expect(server.received, hasLength(3));
        expect(server.received.last.length, 1000);
        expect(eventsOf(BytesLogOp.uploadGaveUp), isEmpty);
      });

      test('a refused request is not retried; its answer travels with the '
          'error', () async {
        server.statuses.add(400);

        await expectLater(
          client.upload(
            server.url(),
            body: HttpBytesUploadBody.file(file.path, length: 1000),
            retry: HttpBytesRetryBackoff.uploadPart,
            retryWait: recordWait,
          ),
          throwsA(
            isA<HttpBytesException$Request>().having(
              (e) => (e.data! as Map<String, Object?>)['body'],
              'body',
              isNotNull,
            ),
          ),
        );

        expect(server.received, hasLength(1));
        expect(waits, isEmpty);
        expect(eventsOf(BytesLogOp.uploadGaveUp).single.fields['attempts'], 1);
      });

      test('without a backoff an upload is sent once', () async {
        server.statuses.add(503);

        await expectLater(
          client.upload(
            server.url(),
            body: HttpBytesUploadBody.file(file.path, length: 1000),
          ),
          throwsA(isA<HttpBytesException$Server>()),
        );
        expect(server.received, hasLength(1));
      });

      test('cancelling during a wait ends the upload', () async {
        server.statuses.add(503);
        final token = CancelToken();
        final waiting = Completer<void>();

        final upload = client.upload(
          server.url(),
          body: HttpBytesUploadBody.file(file.path, length: 1000),
          cancelToken: token,
          retry: HttpBytesRetryBackoff.uploadPart,
          retryWait: (_) {
            waiting.complete();
            return Completer<void>().future;
          },
        );
        await waiting.future;
        token.cancel();

        await expectLater(upload, throwsA(isA<HttpBytesException$Cancelled>()));
        expect(server.received, hasLength(1));
      });
    });
  });

  group('HttpBytesRetryBackoff.uploadPart', () {
    const preset = HttpBytesRetryBackoff.uploadPart;

    test('pins five tries, from 1 s, each wait capped at 30 s', () {
      expect(preset.maxRetries, 4);
      expect(preset.initialDelay, const Duration(seconds: 1));
      expect(preset.minDelay, const Duration(seconds: 1));
      expect(preset.maxDelay, const Duration(seconds: 30));
      expect(preset.factor, 2.0);
    });

    test('the budget never stops the series short', () {
      var slept = Duration.zero;
      for (var attempt = 0; attempt < preset.maxRetries; attempt++) {
        expect(preset.withinBudget(slept, preset.maxDelay), isTrue);
        slept += preset.maxDelay;
      }
    });

    test('every wait falls in 1 s..30 s and grows with the attempt', () {
      final random = math.Random(42);
      for (var attempt = 0; attempt < 12; attempt++) {
        final window = math.min(30, 1 << attempt);
        for (var i = 0; i < 50; i++) {
          final delay = preset.backoff(attempt, random);
          expect(delay, greaterThanOrEqualTo(const Duration(seconds: 1)));
          expect(delay, lessThanOrEqualTo(Duration(seconds: window)));
        }
      }
    });

    test('the default backoff keeps full jitter', () {
      const standard = HttpBytesRetryBackoff();
      expect(standard.minDelay, Duration.zero);
      final draws = [
        for (var i = 0; i < 200; i++) standard.backoff(0, math.Random(i)),
      ];
      expect(
        draws.any((d) => d < const Duration(milliseconds: 20)),
        isTrue,
      );
    });
  });
}
