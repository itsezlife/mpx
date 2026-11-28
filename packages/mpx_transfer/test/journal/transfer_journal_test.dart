import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart' show RequestPriority;
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/src/journal/journal_codec.dart';
import 'package:mpx_transfer/src/journal/journal_record.dart';
import 'package:mpx_transfer/src/journal/transfer_journal.dart';
import 'package:mpx_transfer/testing.dart';

final DateTime _t0 = DateTime.utc(2026, 11, 27);

TransferJob _job(String name, TransferState state) => TransferJob(
  id: TransferId.parse('u-$name'),
  direction: TransferDirection.upload,
  durability: TransferDurability.system,
  state: state,
  createdAt: _t0,
  updatedAt: _t0,
);

Future<TransferJournal> _open(
  JournalStore store, {
  int compactAfter = TransferJournal.defaultCompactAfter,
}) => TransferJournal.open(
  store,
  retention: const Duration(hours: 24),
  progressInterval: const Duration(hours: 1),
  now: () => _t0,
  compactAfter: compactAfter,
  resultCodecs: const [FakeTransferResult.codec],
);

void main() {
  group('codec', () {
    final codec = JournalCodec(const [FakeTransferResult.codec]);

    // Through JSON text, as a frame holds it.
    JournalRecord roundTrip(JournalRecord record) {
      final stored = jsonDecode(
        jsonEncode(codec.encode(JournalEntry$Put(record))),
      );
      return (codec.decode(stored) as JournalEntry$Put).record;
    }

    test('every field of a record reads back', () {
      final record = JournalRecord(
        job: TransferJob(
          id: TransferId.forDownload('cache-key'),
          direction: TransferDirection.download,
          durability: TransferDurability.inProcess,
          state: const TransferState.running(
            done: 5,
            total: 9,
            estimated: true,
          ),
          createdAt: DateTime(2026, 11, 27, 10, 30, 0, 1, 2),
          updatedAt: _t0,
          tag: 'chat:1:m1',
          key: const MediaKey.remote('photo-1'),
          priority: RequestPriority.background,
          resumeOnStart: false,
        ),
        upload: JournalUpload(
          source: JournalSource(
            path: '/tmp/source.mp4',
            size: 42,
            growing: true,
            fingerprint: '42-1700000000',
            modified: _t0.subtract(const Duration(minutes: 5)),
          ),
          transportId: 'tus',
          lane: UploadLane.big,
          partSize: 8,
          fileName: 'source.mp4',
          contentType: 'video/mp4',
          resumeToken: 'token',
          resumeExpiresAt: _t0.add(const Duration(hours: 24)),
          parts: const {0: 'etag-0', 1: null, 3: 'etag-3'},
          highWaterMark: 16,
        ),
        envelopeHandle: 'handle',
        lastProgressAt: _t0.add(const Duration(seconds: 1)),
      );
      expect(roundTrip(record), record);
    });

    test('every state reads back', () {
      for (final state in const [
        TransferState.queued(),
        TransferState.queued(total: 3),
        TransferState.running(done: 1),
        TransferState.paused(reason: PauseReason.awaitingResume, done: 2),
        TransferState.failed(
          kind: TransferFailureKind.sourceLost,
          retryable: false,
          done: 1,
          total: 4,
        ),
        TransferState.completed(FakeTransferResult('ref')),
      ]) {
        final record = JournalRecord(job: _job('a', state));
        expect(roundTrip(record), record, reason: '$state');
      }
    });

    test('a record whose result kind no codec knows throws a '
        'FormatException naming the kind', () {
      final stored = codec.encode(
        JournalEntry$Put(
          JournalRecord(
            job: _job(
              'a',
              const TransferState.completed(FakeTransferResult('r')),
            ),
          ),
        ),
      );
      expect(
        () => JournalCodec(const []).decode(stored),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('fake'),
          ),
        ),
      );
    });
  });

  group('journal', () {
    late RecordingDiagnostics recorder;

    setUp(() => recorder = RecordingDiagnostics.install());

    test('a log older than the snapshot is not replayed over it', () async {
      final store = MemoryJournalStore();
      final journal = await _open(store)
        ..writeState(_job('a', const TransferState.queued()));
      await journal.idle;
      final staleLog = store.bytesOf(JournalBlob.log);
      journal.writeState(_job('a', const TransferState.running(done: 5)));
      await journal.compact();
      journal.abandon();
      // A kill between the two steps of that compaction: the new snapshot
      // beside the log it replaced.
      await store.replace(
        snapshot: store.bytesOf(JournalBlob.snapshot),
        log: staleLog,
      );

      final again = await _open(store);
      expect(again.jobs, [_job('a', const TransferState.running(done: 5))]);
      await again.close();
    });

    test('a whole frame that does not read back is skipped and counted, '
        'not torn', () async {
      final store = MemoryJournalStore();
      final journal = await _open(store)
        ..writeState(
          _job('a', const TransferState.completed(FakeTransferResult('r'))),
        )
        ..writeState(_job('b', const TransferState.queued()));
      await journal.close();
      recorder.clear();
      // A build that knows no codec for the result kind.
      final again = await TransferJournal.open(
        store,
        retention: const Duration(hours: 24),
        now: () => _t0,
      );
      expect(again.jobs.map((job) => job.id.value), ['u-b']);
      expect(recorder.whereOp(JournalOp.replayed).single.fields['skipped'], 1);
      expect(recorder.whereOp(JournalOp.tornTailDropped), isEmpty);
      await again.close();
    });

    test('a frame whose checksum fails ends the log there', () async {
      final store = MemoryJournalStore();
      final journal = await _open(store)
        ..writeState(_job('a', const TransferState.queued()));
      await journal.close();
      final snapshot = store.bytesOf(JournalBlob.snapshot);
      // A frame of zeros, as some file systems leave after a kill.
      final zeroed = Uint8List.fromList(snapshot)
        ..fillRange(snapshot.length - 4, snapshot.length, 0);
      await store.replace(snapshot: zeroed, log: Uint8List(0));
      recorder.clear();
      final again = await _open(store);
      expect(again.jobs, isEmpty);
      expect(recorder.whereOp(JournalOp.tornTailDropped), hasLength(1));
      await again.close();
    });

    test('folds the log every compactAfter records', () async {
      final journal = await _open(MemoryJournalStore(), compactAfter: 3);
      recorder.clear();
      for (var done = 0; done < 3; done++) {
        journal.writeState(_job('a', TransferState.running(done: done)));
      }
      await journal.idle;
      expect(recorder.whereOp(JournalOp.compacted), hasLength(1));
      expect(journal.debugSnapshot().recordsSinceCompaction, 0);
      await journal.close();
    });

    test('writes after a close are ignored', () async {
      final store = MemoryJournalStore();
      final journal = await _open(store);
      await journal.close();
      journal.writeState(_job('a', const TransferState.queued()));
      await journal.idle;
      expect((await _open(store)).jobs, isEmpty);
    });
  });
}
