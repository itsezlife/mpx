import 'package:flutter_test/flutter_test.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart'
    show HttpBytesException$Server, HttpBytesRetryBackoff;
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/src/journal/transfer_journal.dart';
import 'package:mpx_transfer/src/upload/upload_engine.dart';
import 'package:mpx_transfer/testing.dart';

import 'upload_support.dart';

void main() {
  group('split', () {
    test('parts follow the size the transport declares for the file', () async {
      final transport = FakeUploadTransport(
        capabilities: UploadCapabilities(
          partSize: (size) => size > 1000 ? 400 : 100,
          bytesInFlight: 1 << 20,
          reuse: const UploadReuse.lifetime(Duration(hours: 1)),
        ),
      );
      final h = await uploads([transport]);
      h
        ..upload(sourceOf(250))
        ..upload(sourceOf(1100));
      await pumpEventQueue();

      expect(transport.opens.map((open) => open.info), [
        const UploadInfo(size: 250, partSize: 100, partCount: 3),
        const UploadInfo(size: 1100, partSize: 400, partCount: 3),
      ]);
      expect(transport.sent, [
        const FakeUploadPart(index: 0, offset: 0, length: 100, last: false),
        const FakeUploadPart(index: 1, offset: 100, length: 100, last: false),
        const FakeUploadPart(index: 2, offset: 200, length: 50, last: true),
        const FakeUploadPart(index: 0, offset: 0, length: 400, last: false),
        const FakeUploadPart(index: 1, offset: 400, length: 400, last: false),
        const FakeUploadPart(index: 2, offset: 800, length: 300, last: true),
      ]);
    });

    test('an empty file is one empty part', () async {
      final transport = fakeTransport();
      final h = await uploads([transport]);
      final id = h.upload(sourceOf(0));
      await pumpEventQueue();

      expect(transport.sent, [
        const FakeUploadPart(index: 0, offset: 0, length: 0, last: true),
      ]);
      expect(await stateOf(h.transfers, id), isA<TransferState$Completed>());
    });

    test('a completed upload holds the RemoteRef its transport finished '
        'with, and every acknowledgement went to finish in order', () async {
      final transport = fakeTransport(partSize: 10, bytesInFlight: 30);
      final h = await uploads([transport]);
      final id = h.upload(sourceOf(25));
      await pumpEventQueue();

      expect(
        await stateOf(h.transfers, id),
        TransferState.completed(RemoteRef('fake-1')),
      );
      expect(transport.finishes.single.finalSize, 25);
      expect(transport.finishes.single.parts, const [
        UploadPartAck(receipt: 'receipt-0'),
        UploadPartAck(receipt: 'receipt-1'),
        UploadPartAck(receipt: 'receipt-2'),
      ]);
    });
  });

  group('bytes in flight', () {
    test('the budget holds with parts that do not divide it', () async {
      // Parts of 300 under a budget of 1000: three fit, a fourth would not.
      final transport = fakeTransport(
        partSize: 300,
        bytesInFlight: 1000,
        holdParts: true,
      );
      final h = await uploads([transport]);
      h.upload(sourceOf(1500));
      await pumpEventQueue();
      expect(transport.held, [0, 1, 2]);
      expect(transport.bytesInFlight, 900);

      transport.ack(1);
      await pumpEventQueue();
      expect(transport.held, [0, 2, 3]);

      // The last part is shorter (300 of 1500 is even here; take the uneven
      // case below): every step stays within the budget.
      transport
        ..ack(0)
        ..ack(2);
      await pumpEventQueue();
      transport
        ..ack(3)
        ..ack(4);
      await pumpEventQueue();
      expect(transport.maxBytesInFlight, lessThanOrEqualTo(1000));
      expect(transport.finishes, hasLength(1));
    });

    test('a short last part joins when it fits where a whole part would '
        'not', () async {
      final transport = fakeTransport(
        partSize: 400,
        bytesInFlight: 900,
        holdParts: true,
      );
      final h = await uploads([transport]);
      h.upload(sourceOf(900)); // 400, 400, 100
      await pumpEventQueue();
      expect(transport.held, [0, 1, 2]);
      expect(transport.bytesInFlight, 900);
    });

    test('a budget under the part size sends one part at a time', () async {
      final transport = fakeTransport(
        partSize: 100,
        bytesInFlight: 0,
        holdParts: true,
      );
      final h = await uploads([transport]);
      h.upload(sourceOf(300));
      await pumpEventQueue();
      expect(transport.held, [0]);
      transport.ack(0);
      await pumpEventQueue();
      expect(transport.held, [1]);
    });

    test('parts acknowledged out of order are each sent once', () async {
      final transport = fakeTransport(
        partSize: 10,
        bytesInFlight: 40,
        holdParts: true,
      );
      final h = await uploads([transport]);
      final id = h.upload(sourceOf(40));
      await pumpEventQueue();
      for (final index in [3, 1, 2, 0]) {
        transport.ack(index);
        await pumpEventQueue();
      }

      expect(transport.acknowledged, [3, 1, 2, 0]);
      expect(transport.sent.map((part) => part.index), [0, 1, 2, 3]);
      expect(await stateOf(h.transfers, id), isA<TransferState$Completed>());
    });
  });

  group('retry', () {
    test('a part that fails four times and then succeeds lands, after '
        'waits inside 1 s..30 s', () async {
      final waits = <Duration>[];
      final transport = fakeTransport(partSize: 10)..failPart(1, times: 4);
      final h = await uploads([transport], waits: waits);
      final id = h.upload(sourceOf(30));
      await pumpEventQueue();

      expect(await stateOf(h.transfers, id), isA<TransferState$Completed>());
      expect(transport.sent.where((part) => part.index == 1), hasLength(5));
      expect(waits, hasLength(4));
      for (final wait in waits) {
        expect(wait, greaterThanOrEqualTo(const Duration(seconds: 1)));
        expect(wait, lessThanOrEqualTo(const Duration(seconds: 30)));
      }
    });

    test('a part that fails five times fails the upload, retryable', () async {
      final transport = fakeTransport(partSize: 10)..failPart(0, times: 5);
      final h = await uploads([transport], waits: []);
      final id = h.upload(sourceOf(30));
      await pumpEventQueue();

      expect(
        await stateOf(h.transfers, id),
        const TransferState.failed(
          kind: TransferFailureKind.server,
          retryable: true,
          done: 20,
          total: 30,
        ),
      );
      expect(transport.sent.where((part) => part.index == 0), hasLength(5));
      expect(transport.finishes, isEmpty);
    });

    test('a refusal that cannot pass fails at once, not retryable', () async {
      final transport = fakeTransport(partSize: 10)
        ..failPart(
          0,
          error: const HttpBytesException$Server(
            code: 'bad_request',
            message: 'refused',
            statusCode: 400,
          ),
        );
      final h = await uploads([transport], waits: []);
      final id = h.upload(sourceOf(10));
      await pumpEventQueue();

      expect(
        await stateOf(h.transfers, id),
        const TransferState.failed(
          kind: TransferFailureKind.server,
          retryable: false,
          total: 10,
        ),
      );
      expect(transport.sent, hasLength(1));
    });

    test('opening and finishing are tried again like a part', () async {
      final transport = fakeTransport()
        ..failOpen(times: 2)
        ..failFinish(times: 3);
      final h = await uploads([transport], waits: []);
      final id = h.upload(sourceOf(10));
      await pumpEventQueue();

      expect(transport.opens, hasLength(3));
      expect(transport.finishes, hasLength(4));
      expect(await stateOf(h.transfers, id), isA<TransferState$Completed>());
    });

    test('defaults: the upload part preset, the 10 MiB lane split and '
        'the connection caps', () async {
      final journal = await TransferJournal.open(
        MemoryJournalStore(),
        retention: const Duration(hours: 24),
      );
      final engine = UploadEngine(journal: journal, transports: const []);
      expect(engine.retry, same(HttpBytesRetryBackoff.uploadPart));
      expect(engine.retry.maxRetries, 4);
      expect(engine.retry.initialDelay, const Duration(seconds: 1));
      expect(engine.retry.maxDelay, const Duration(seconds: 30));
      expect(engine.laneSplit, 10 * 1024 * 1024);
      expect(UploadLane.defaultSplit, 10 * 1024 * 1024);
      expect(engine.slots.cap, 8);
      expect(engine.slots.downloadCap, 6);
      expect(engine.slots.uploadCap, 6);
      await journal.close();
    });

    test(
      'a retry of a failed job sends only the parts not acknowledged',
      () async {
        final transport = fakeTransport(partSize: 10)..failPart(2, times: 5);
        final h = await uploads([transport], waits: []);
        final id = h.upload(sourceOf(30));
        await pumpEventQueue();
        expect(await stateOf(h.transfers, id), isA<TransferState$Failed>());

        h.transfers.retry(id);
        await pumpEventQueue();
        expect(await stateOf(h.transfers, id), isA<TransferState$Completed>());
        expect(transport.opens.last.resumeToken, isNotNull);
        expect(transport.acknowledged, [0, 1, 2]);
      },
    );
  });

  group('journal', () {
    test('every acknowledged part is kept with its receipt and the '
        'high-water mark', () async {
      final transport = fakeTransport(
        partSize: 10,
        bytesInFlight: 30,
        holdParts: true,
      );
      final h = await uploads([transport]);
      final id = h.upload(sourceOf(30));
      await pumpEventQueue();
      transport.ack(1, receipt: 'b');
      await pumpEventQueue();
      expect(h.uploadOf(id)!.parts, {1: 'b'});
      expect(h.uploadOf(id)!.highWaterMark, 0);

      transport.ack(0, receipt: 'a');
      await pumpEventQueue();
      expect(h.uploadOf(id)!.parts, {0: 'a', 1: 'b'});
      expect(h.uploadOf(id)!.highWaterMark, 20);
      expect(h.uploadOf(id)!.resumeToken, 'fake-token-1');
    });

    test(
      'the upload facts are written with the job, through the codec',
      () async {
        final transport = fakeTransport(partSize: 10, holdParts: true);
        final h = await uploads([transport]);
        final id = h.upload(
          sourceOf(20),
          fileName: 'a.jpg',
          contentType: 'image/jpeg',
          fingerprint: 'fp',
        );
        await pumpEventQueue();
        transport.ack(0);
        await pumpEventQueue();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await h.settle();
        await h.kill();

        final upload = h.uploadOf(id)!;
        expect(upload.transportId, 'fake');
        expect(upload.lane, UploadLane.small);
        expect(upload.fileName, 'a.jpg');
        expect(upload.contentType, 'image/jpeg');
        expect(upload.source.fingerprint, 'fp');
        expect(upload.source.size, 20);
      },
    );
  });

  group('refusals', () {
    test('a growing source is refused with an UnsupportedError', () async {
      final h = await uploads([fakeTransport()]);
      expect(
        () => h.upload(const UploadSource.growing('/rec.mp4', available: 5)),
        throwsUnsupportedError,
      );
      expect(await h.transfers.watch().first, isEmpty);
    });

    test('a transport the engine was not given is refused', () async {
      final h = await uploads([fakeTransport()]);
      expect(
        () => h.upload(sourceOf(1), transport: 'other'),
        throwsArgumentError,
      );
    });
  });

  group('pause and cancel', () {
    test('a paused upload resumes on the same session token, with the '
        'acknowledged parts kept', () async {
      final transport = fakeTransport(
        partSize: 10,
        bytesInFlight: 10,
        holdParts: true,
      );
      final h = await uploads([transport]);
      final id = h.upload(sourceOf(30));
      await pumpEventQueue();
      transport.ack(0);
      await pumpEventQueue();
      h.transfers.pause(id);
      await pumpEventQueue();
      expect(
        await stateOf(h.transfers, id),
        const TransferState.paused(
          reason: PauseReason.user,
          done: 10,
          total: 30,
        ),
      );

      transport.holdParts = false;
      h.transfers.resume(id);
      await pumpEventQueue();
      // The held try of part 1 is abandoned; it is sent again.
      expect(transport.opens.last.resumeToken, 'fake-token-1');
      expect(transport.sent.map((part) => part.index), [0, 1, 1, 2]);
      expect(await stateOf(h.transfers, id), isA<TransferState$Completed>());
    });

    test('a cancelled upload sends nothing more', () async {
      final transport = fakeTransport(
        partSize: 10,
        bytesInFlight: 10,
        holdParts: true,
      );
      final h = await uploads([transport]);
      final id = h.upload(sourceOf(30));
      await pumpEventQueue();
      h.transfers.cancel(id);
      transport.ack(0);
      await pumpEventQueue();
      expect(transport.sent, hasLength(1));
      expect(await h.transfers.watch().first, isEmpty);
    });
  });
}
