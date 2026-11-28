import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/src/journal/journal_store.dart';

import 'upload_support.dart';

void main() {
  late RecordingDiagnostics recorder;
  late DateTime now;

  setUp(() {
    recorder = RecordingDiagnostics.install();
    now = DateTime.utc(2026, 11, 27);
  });

  test('a clean upload: sessionOpened, partSent and partAcked per part, '
      'finished', () async {
    final transport = fakeTransport(
      partSize: 10,
      bytesInFlight: 20,
      holdParts: true,
    );
    final h = await uploads([transport], now: () => now);
    final id = h.upload(sourceOf(25));
    await pumpEventQueue();
    now = now.add(const Duration(milliseconds: 40));
    for (final index in [1, 0, 2]) {
      transport.ack(index);
      await pumpEventQueue();
    }

    expect(recorder.whereCategory('transport'), [
      isMpxEvent(
        level: MpxEventLevel.debug,
        op: TransportOp.sessionOpened,
        jobId: id,
        fields: {
          'transport': 'fake',
          'resumed': false,
          'offset': 0,
          'size': 25,
        },
      ),
      isMpxEvent(
        level: MpxEventLevel.trace,
        op: TransportOp.partSent,
        jobId: id,
        fields: {'index': 0, 'offset': 0, 'bytes': 10, 'inFlight': 20},
      ),
      isMpxEvent(
        op: TransportOp.partSent,
        fields: {'index': 1, 'offset': 10, 'bytes': 10, 'inFlight': 20},
      ),
      isMpxEvent(
        level: MpxEventLevel.trace,
        op: TransportOp.partAcked,
        jobId: id,
        fields: {'index': 1, 'ms': 40},
      ),
      isMpxEvent(
        op: TransportOp.partSent,
        fields: {'index': 2, 'offset': 20, 'bytes': 5, 'inFlight': 15},
      ),
      isMpxEvent(op: TransportOp.partAcked, fields: {'index': 0, 'ms': 40}),
      isMpxEvent(op: TransportOp.partAcked, fields: {'index': 2, 'ms': 0}),
      isMpxEvent(
        level: MpxEventLevel.info,
        op: TransportOp.finished,
        jobId: id,
        fields: {'finalSize': 25, 'parts': 3, 'ms': 40},
      ),
    ]);
  });

  test('partRetry per failed try with attempt and delay; partGaveUp after '
      'the fifth', () async {
    final waits = <Duration>[];
    final transport = fakeTransport(partSize: 10)..failPart(0, times: 5);
    final h = await uploads([transport], waits: waits);
    final id = h.upload(sourceOf(10));
    await pumpEventQueue();

    final retries = recorder.whereOp(TransportOp.partRetry);
    expect(retries, [
      for (var attempt = 1; attempt <= 4; attempt++)
        isMpxEvent(
          level: MpxEventLevel.warning,
          jobId: id,
          fields: {
            'step': 'part',
            'index': 0,
            'attempt': attempt,
            'delayMs': waits[attempt - 1].inMilliseconds,
            'code': 'fake_failure',
          },
        ),
    ]);
    expect(recorder.whereOp(TransportOp.partGaveUp), [
      isMpxEvent(
        level: MpxEventLevel.error,
        jobId: id,
        fields: {
          'step': 'part',
          'index': 0,
          'attempts': 5,
          'code': 'fake_failure',
        },
      ),
    ]);
    expect(recorder.whereOp(SchedulerOp.failed), hasLength(1));
    expect(h.transfers.debugSnapshot().uploads!.partRetries, 4);
  });

  test('a failure that was an answer reports its status', () async {
    final transport = fakeTransport()
      ..failOpen(error: const UploadTransportException('refused', status: 403));
    final h = await uploads([transport], waits: []);
    h.upload(sourceOf(10));
    await pumpEventQueue();
    expect(
      recorder.whereOp(TransportOp.partGaveUp).single,
      isMpxEvent(fields: {'step': 'open', 'attempts': 1, 'status': 403}),
    );
  });

  test('a job whose transport is gone at a restart fails with an '
      'event', () async {
    final store = MemoryJournalStore();
    final h = await uploads([
      fakeTransport(holdParts: true),
    ], store: () => store);
    final id = h.upload(sourceOf(10));
    await pumpEventQueue();
    await h.transfers.dispose();
    // A start over the same journal without the transport stands in for a
    // host that no longer registers it.
    final other = await uploads([], store: () => store);
    await pumpEventQueue();
    expect(
      recorder.whereOp(TransportOp.partGaveUp).last,
      isMpxEvent(
        jobId: id,
        fields: {'step': 'open', 'attempts': 0, 'code': 'unknown_transport'},
      ),
    );
    expect(await stateOf(other.transfers, id), isA<TransferState$Failed>());
  });

  test('no transport event carries the path, the file name or the resume '
      'token', () async {
    final transport = fakeTransport(partSize: 10)..failPart(1);
    final h = await uploads([transport], waits: []);
    h.upload(sourceOf(30), fileName: 'holiday.jpg');
    await pumpEventQueue();
    await h.restart();
    await pumpEventQueue();

    final values = [
      for (final event in recorder.events)
        for (final value in event.fields.values) '$value',
    ];
    expect(recorder.whereCategory('transport'), isNotEmpty);
    for (final value in values) {
      expect(value, isNot(contains('/uploads')));
      expect(value, isNot(contains('holiday')));
      expect(value, isNot(contains('fake-token')));
      expect(value, isNot(contains('receipt')));
    }
  });
}
