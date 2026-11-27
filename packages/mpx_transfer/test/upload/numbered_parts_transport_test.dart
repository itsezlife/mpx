import 'dart:ui' show AppLifecycleState;

import 'package:flutter_test/flutter_test.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/testing.dart';

import '../support/numbered_parts_protocol.dart';
import '../support/upload_test_server.dart';

const int _kib = 1024;
const int _mib = 1024 * 1024;

/// The parts of the tests over the server: small, so files stay small.
const int _part = 64 * _kib;

void main() {
  group('defaults', () {
    final transport = NumberedPartsTransport(
      start: (_) async => 'u',
      partRequest: (_) => NumberedPartRequest(Uri.parse('http://h/p')),
      complete: (_) async => RemoteRef('f'),
    );

    test('parts of 128 KiB, 512 KiB above 10 MiB, larger beyond 4000 '
        'parts', () {
      expect(NumberedPartsTransport.defaultSmallPartSize, 128 * _kib);
      expect(NumberedPartsTransport.defaultBigPartSize, 512 * _kib);
      expect(NumberedPartsTransport.defaultBigPartsAbove, 10 * _mib);
      expect(NumberedPartsTransport.defaultMaxParts, 4000);

      final partSize = transport.capabilities.partSize;
      expect(partSize(0), 128 * _kib);
      expect(partSize(10 * _mib), 128 * _kib);
      expect(partSize(10 * _mib + 1), 512 * _kib);
      expect(partSize(4000 * 512 * _kib), 512 * _kib);
      // One byte more would need part 4001: parts grow to the next
      // multiple of 512 KiB.
      expect(partSize(4000 * 512 * _kib + 1), _mib);
      expect(partSize(4 * 1024 * _mib), 1536 * _kib);
      for (final size in [4000 * 512 * _kib + 1, 4 * 1024 * _mib]) {
        expect((size / partSize(size)).ceil(), lessThanOrEqualTo(4000));
      }
    });

    test('8 MiB in flight', () {
      expect(NumberedPartsTransport.defaultBytesInFlight, 8 * _mib);
      expect(transport.capabilities.bytesInFlight, 8 * _mib);
    });

    test('a resume window of 1.5 h up to the 10 MiB lane split, 24 h '
        'above it', () {
      expect(
        NumberedPartsTransport.defaultSmallFileWindow,
        const Duration(minutes: 90),
      );
      expect(
        NumberedPartsTransport.defaultBigFileWindow,
        const Duration(hours: 24),
      );
      expect(transport.windowSplit, UploadLane.defaultSplit);
      final resume = transport.capabilities.resume as UploadResume$Window;
      expect(resume.window(10 * _mib), const Duration(minutes: 90));
      expect(resume.window(10 * _mib + 1), const Duration(hours: 24));
    });

    test('thumbnails go separate; a stored reference is good for 24 h', () {
      expect(transport.capabilities.thumbnail, UploadThumbnail.separate);
      final reuse = transport.capabilities.reuse as UploadReuse$Lifetime;
      expect(reuse.lifetime, const Duration(hours: 24));
      expect(transport.capabilities.knownSizeRequired, isTrue);
      expect(transport.capabilities.headLastAllowed, isFalse);
      expect(transport.id, 'numberedParts');
    });

    test('presigned multipart: parts of 8 MiB, at most 10 000, 32 MiB in '
        'flight, the same windows, thumbnail and reuse', () {
      final presigned = NumberedPartsTransport.presignedMultipart(
        start: (_) async => 'u',
        partRequest: (_) => NumberedPartRequest(Uri.parse('http://h/p')),
        complete: (_) async => RemoteRef('f'),
      );
      expect(presigned.id, 'presignedMultipart');
      final partSize = presigned.capabilities.partSize;
      expect(partSize(1), 8 * _mib);
      expect(partSize(100 * _mib), 8 * _mib);
      expect(partSize(10000 * 8 * _mib), 8 * _mib);
      expect(partSize(10000 * 8 * _mib + 1), 16 * _mib);
      expect(presigned.capabilities.bytesInFlight, 32 * _mib);
      final resume = presigned.capabilities.resume as UploadResume$Window;
      expect(resume.window(_mib), const Duration(minutes: 90));
      expect(resume.window(11 * _mib), const Duration(hours: 24));
      expect(presigned.capabilities.thumbnail, UploadThumbnail.separate);
      expect(
        (presigned.capabilities.reuse as UploadReuse$Lifetime).lifetime,
        const Duration(hours: 24),
      );
    });
  });

  group('over the local server', () {
    late UploadTestServer server;
    late NumberedPartsProtocol protocol;
    late HttpBytesClient client;

    setUp(() async {
      server = await UploadTestServer.start();
      protocol = NumberedPartsProtocol(server, minPartSize: _part);
      client = HttpBytesClient(
        transfers: const HttpBytesTransfers(landBytes: 64 * 1024),
      );
    });

    tearDown(() async {
      await client.close();
      await server.close();
    });

    UploadTransportContract.run(
      'NumberedPartsTransport, numbered endpoint',
      transport: () =>
          numberedTransport(protocol, smallPartSize: _part, bytesInFlight: 0),
      client: () => client,
      received: (ref) async => server.files[ref.id],
    );

    UploadTransportContract.run(
      'NumberedPartsTransport, presigned multipart',
      transport: () => presignedTransport(protocol, partSize: _part),
      client: () => client,
      received: (ref) async => server.files[ref.id],
    );

    late RecordingDiagnostics recorder;
    late DateTime now;
    late List<Duration> waits;

    Future<UploadsHarness> harness(UploadTransport transport) async {
      recorder = RecordingDiagnostics.install();
      now = DateTime.utc(2026, 11, 27, 12);
      waits = [];
      final built = await UploadsHarness.open(
        lifecycle: ManualPlaybackLifecycleSource(
          initial: AppLifecycleState.resumed,
        ),
        transports: [transport],
        client: client,
        now: () => now,
        progressInterval: Duration.zero,
        wait: (delay) async => waits.add(delay),
      );
      addTearDown(() => built.transfers.dispose());
      return built;
    }

    Future<({UploadSource source, List<int> bytes})> fileOf(int size) async {
      final bytes = [for (var i = 0; i < size; i++) (i * 13 + 5) & 0xff];
      return (source: await UploadSource.fromBytes(bytes), bytes: bytes);
    }

    Future<TransferState?> settled(UploadsHarness h, TransferId id) async {
      for (var i = 0; i < 400; i++) {
        final state = await stateIn(h.transfers, id);
        if (state is TransferState$Completed || state is TransferState$Failed) {
          return state;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return stateIn(h.transfers, id);
    }

    Future<void> until(bool Function() condition) async {
      for (var i = 0; i < 400 && !condition(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(condition(), isTrue);
    }

    test('presigned multipart end to end: initiate, signed part PUTs in '
        'parallel, complete with every part and its ETag in order', () async {
      final h = await harness(
        presignedTransport(protocol, partSize: _part, bytesInFlight: 3 * _part),
      );
      protocol.holdParts(0);
      final (:source, :bytes) = await fileOf(5 * _part + 100);
      final id = h.upload(source);
      await until(() => protocol.concurrentParts == 3);
      protocol.releaseHeld();

      expect(
        await settled(h, id),
        TransferState.completed(RemoteRef('media/object-1.bin')),
      );
      expect(protocol.presignedStarts, 1);
      expect(protocol.completions.single, [1, 2, 3, 4, 5, 6]);
      expect(server.files['media/object-1.bin'], bytes);
      expect(protocol.maxConcurrentParts, 3);
      expect([
        for (final part in protocol.received) part.length,
      ], unorderedEquals([for (var i = 0; i < 5; i++) _part, 100]));
    });

    test('parts go out in parallel and stay within the bytes-in-flight '
        'budget', () async {
      final h = await harness(
        numberedTransport(
          protocol,
          smallPartSize: _part,
          bytesInFlight: 4 * _part,
        ),
      );
      protocol.holdParts(0);
      final (:source, :bytes) = await fileOf(10 * _part);
      final id = h.upload(source);

      await until(() => protocol.concurrentParts == 4);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(protocol.concurrentParts, 4);
      protocol.releaseHeld();

      expect(await settled(h, id), isA<TransferState$Completed>());
      expect(protocol.maxConcurrentParts, 4);
      expect(protocol.completions.single, [for (var n = 1; n <= 10; n++) n]);
      final ref = (await stateIn(h.transfers, id))! as TransferState$Completed;
      expect(server.files[(ref.result as RemoteRef).id], bytes);
    });

    test('a failed part request is tried again with one partRetry, and the '
        'events carry no URL, upload id or receipt', () async {
      final h = await harness(
        numberedTransport(protocol, smallPartSize: _part, bytesInFlight: 0),
      );
      protocol.failParts(1, status: 503);
      final (:source, bytes: _) = await fileOf(3 * _part);
      final id = h.upload(source);

      expect(await settled(h, id), isA<TransferState$Completed>());
      final retries = recorder.whereOp(TransportOp.partRetry);
      expect(retries, [
        isMpxEvent(
          level: MpxEventLevel.warning,
          op: TransportOp.partRetry,
          jobId: id,
          fields: {
            'step': 'part',
            'index': 0,
            'attempt': 1,
            'delayMs': waits.single.inMilliseconds,
            'status': 503,
          },
        ),
      ]);
      expect(recorder.whereOp(TransportOp.finished), hasLength(1));
      for (final event in recorder.whereCategory('transport')) {
        for (final value in event.fields.values) {
          expect('$value', isNot(contains('127.0.0.1')));
          expect('$value', isNot(contains('n0')));
        }
      }
    });

    test('a refused part (a bad signature) fails the upload without a '
        'retry: partGaveUp, not retryable', () async {
      final transport = NumberedPartsTransport.presignedMultipart(
        partSize: _part,
        start: (_) async => 'unknown',
        partRequest: (part) => NumberedPartRequest(
          server
              .url('/bucket/k')
              .replace(
                queryParameters: {
                  'partNumber': '${part.number}',
                  'uploadId': part.uploadId,
                  'X-Amz-Signature': 'wrong',
                },
              ),
        ),
        complete: (_) async => RemoteRef('k'),
      );
      final h = await harness(transport);
      final (:source, bytes: _) = await fileOf(_part);
      final id = h.upload(source);

      final state = await settled(h, id);
      expect(state, isA<TransferState$Failed>());
      expect((state! as TransferState$Failed).retryable, isFalse);
      expect(recorder.whereOp(TransportOp.partRetry), isEmpty);
      expect(recorder.whereOp(TransportOp.partGaveUp), [
        isMpxEvent(
          level: MpxEventLevel.error,
          op: TransportOp.partGaveUp,
          jobId: id,
          fields: {'step': 'part', 'index': 0, 'attempts': 1, 'status': 403},
        ),
      ]);
      expect(waits, isEmpty);
    });

    test('a kill, then a restart within the window, sends only the parts '
        'not acknowledged and completes with every part', () async {
      final h = await harness(
        numberedTransport(protocol, smallPartSize: _part, bytesInFlight: 0),
      );
      protocol.holdParts(3);
      final (:source, :bytes) = await fileOf(8 * _part);
      final id = h.upload(source);
      await until(
        () => protocol.concurrentParts == 1 && protocol.received.length == 3,
      );
      await until(() => h.uploadOf(id)!.parts.length == 3);
      await h.settle();

      now = now.add(const Duration(minutes: 80));
      await h.kill();
      final before = protocol.received.length;
      protocol.releaseHeld();

      final state = await settled(h, id);
      expect(state, isA<TransferState$Completed>());
      expect(protocol.numberedStarts, 1);
      final sentAfter = [
        for (final part in protocol.received.skip(before)) part.number,
      ];
      // Part 4 was on the wire at the kill: it lands from the killed run
      // as well as from the new one.
      expect(sentAfter.where((n) => n != 4), [5, 6, 7, 8]);
      expect(sentAfter, contains(4));
      expect(protocol.completions.single, [for (var n = 1; n <= 8; n++) n]);
      final ref = (state! as TransferState$Completed).result as RemoteRef;
      expect(server.files[ref.id], bytes);
    });

    test('a kill, then a restart after the window, starts the upload from '
        'zero', () async {
      final h = await harness(
        numberedTransport(protocol, smallPartSize: _part, bytesInFlight: 0),
      );
      protocol.holdParts(3);
      final (:source, :bytes) = await fileOf(8 * _part);
      final id = h.upload(source);
      await until(() => protocol.received.length == 3);
      await until(() => h.uploadOf(id)!.parts.length == 3);
      await h.settle();

      now = now.add(const Duration(minutes: 91));
      await h.kill();
      final before = protocol.received.length;
      protocol.releaseHeld();

      final state = await settled(h, id);
      expect(state, isA<TransferState$Completed>());
      expect(protocol.numberedStarts, 2);
      expect(
        [
          for (final part in protocol.received.skip(before))
            if (part.uploadId != 'n0') part.number,
        ],
        [for (var n = 1; n <= 8; n++) n],
      );
      final ref = (state! as TransferState$Completed).result as RemoteRef;
      expect(server.files[ref.id], bytes);
    }, skip: 'Until the engine applies the resume window at a restart.');
  });
}

/// The state of job [id] now, or null when there is no such job.
Future<TransferState?> stateIn(Transfers transfers, TransferId id) async {
  for (final job in await transfers.watch().first) {
    if (job.id == id) return job.state;
  }
  return null;
}
