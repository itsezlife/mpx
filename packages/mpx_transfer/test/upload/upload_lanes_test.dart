import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/src/engine/connection_slots.dart';

import 'upload_support.dart';

void main() {
  group('lanes', () {
    test('two small jobs run one after the other while a big job runs '
        'beside them', () async {
      final transport = fakeTransport(partSize: 1000, holdParts: true);
      final h = await uploads([transport]);
      final first = h.upload(sourceOf(100));
      final second = h.upload(sourceOf(200));
      final big = h.upload(sourceOf(300), lane: UploadLane.big);
      await pumpEventQueue();

      expect(transport.opens.map((open) => open.info.size), [100, 300]);
      expect(await stateOf(h.transfers, second), isA<TransferState$Queued>());
      final lanes = h.transfers.debugSnapshot().uploads!.lanes;
      expect(lanes[UploadLane.small]!.running, first);
      expect(lanes[UploadLane.small]!.queued, 1);
      expect(lanes[UploadLane.big]!.running, big);
      expect(lanes[UploadLane.big]!.queued, 0);

      transport.ack(0); // the first small job's only part
      await pumpEventQueue();
      expect(await stateOf(h.transfers, first), isA<TransferState$Completed>());
      expect(transport.opens.map((open) => open.info.size), [100, 300, 200]);
      expect(
        h.transfers.debugSnapshot().uploads!.lanes[UploadLane.small]!.running,
        second,
      );
    });

    test('a paused job frees its lane for the next', () async {
      final transport = fakeTransport(partSize: 1000, holdParts: true);
      final h = await uploads([transport]);
      final first = h.upload(sourceOf(100));
      h.upload(sourceOf(200));
      await pumpEventQueue();
      h.transfers.pause(first);
      await pumpEventQueue();
      expect(transport.opens.map((open) => open.info.size), [100, 200]);
    });

    test('the split is 10 MiB: up to it small, above it big', () async {
      expect(UploadLane.defaultSplit, 10 * 1024 * 1024);
      final h = await uploads([fakeTransport(holdParts: true)]);
      final atSplit = h.upload(sourceOf(10 * 1024 * 1024));
      final above = h.upload(sourceOf(10 * 1024 * 1024 + 1));
      expect(h.uploadOf(atSplit)!.lane, UploadLane.small);
      expect(h.uploadOf(above)!.lane, UploadLane.big);
    });

    test('the split is a field', () async {
      final h = await uploads([fakeTransport(holdParts: true)], laneSplit: 50);
      expect(h.uploadOf(h.upload(sourceOf(51)))!.lane, UploadLane.big);
    });

    test('jobQueued and jobStarted carry the lane; jobStarted the wait in '
        'it', () async {
      final recorder = RecordingDiagnostics.install();
      var now = DateTime.utc(2026, 11, 27);
      final transport = fakeTransport(partSize: 1000, holdParts: true);
      final h = await uploads([transport], now: () => now);
      h.upload(sourceOf(100), tag: 't');
      final second = h.upload(sourceOf(100), tag: 't');
      await pumpEventQueue();
      now = now.add(const Duration(seconds: 3));
      transport.ack(0);
      await pumpEventQueue();

      expect(
        recorder.whereOp(SchedulerOp.jobQueued).map((e) => e.fields['lane']),
        ['small', 'small'],
      );
      expect(
        recorder.whereOp(SchedulerOp.jobStarted).last,
        isMpxEvent(
          jobId: second,
          tag: 't',
          fields: {'lane': 'small', 'durability': 'system', 'waitedMs': 3000},
        ),
      );
    });
  });

  group('connections', () {
    test('caps: 8 in all, downloads at most 6, uploads at most 6', () async {
      final slots = ConnectionSlots();
      final id = TransferId.issue();
      final uploads = [
        for (var i = 0; i < 6; i++)
          await slots.acquire(TransferDirection.upload, id),
      ];
      var waited = false;
      final seventh = slots
          .acquire(TransferDirection.upload, id)
          .then((slot) => waited = true);
      await pumpEventQueue();
      expect(waited, isFalse);

      // Uploads at their cap leave two for downloads.
      await slots.acquire(TransferDirection.download, id);
      await slots.acquire(TransferDirection.download, id);
      expect(slots.debugSnapshot().downloads, 2);

      uploads.first.release();
      await seventh;
      expect(slots.inUse(TransferDirection.upload), 6);
    });

    test('an upload holds no more connections than the upload cap, however '
        'large its budget', () async {
      final transport = fakeTransport(
        partSize: 10,
        bytesInFlight: 1000,
        holdParts: true,
      );
      final h = await uploads([transport]);
      h.upload(sourceOf(100));
      await pumpEventQueue();
      expect(transport.held, hasLength(6));
      expect(h.transfers.debugSnapshot().connections!.uploads, 6);
      expect(h.transfers.debugSnapshot().uploads!.partsInFlight, 10);

      transport.ack(0);
      await pumpEventQueue();
      expect(transport.held, hasLength(6));
    });

    test(
      'slotAcquired and slotReleased carry direction, in use and cap',
      () async {
        final recorder = RecordingDiagnostics.install();
        final slots = ConnectionSlots();
        final id = TransferId.issue();
        (await slots.acquire(TransferDirection.upload, id)).release();
        expect(recorder.whereCategory('scheduler'), [
          isMpxEvent(
            level: MpxEventLevel.trace,
            op: SchedulerOp.slotAcquired,
            jobId: id,
            fields: {'direction': 'upload', 'inUse': 1, 'cap': 6},
          ),
          isMpxEvent(
            level: MpxEventLevel.trace,
            op: SchedulerOp.slotReleased,
            jobId: id,
            fields: {'direction': 'upload', 'inUse': 0, 'cap': 6},
          ),
        ]);
      },
    );
  });
}
