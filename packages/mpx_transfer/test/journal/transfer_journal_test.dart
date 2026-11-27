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

    JournalRecord roundTrip(JournalRecord record) {
      final read = codec.decode(codec.encode([JournalEntry$Put(record)]));
      expect(read.tornBytes, 0);
      expect(read.skipped, 0);
      return (read.entries.single as JournalEntry$Put).record;
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
        source: const JournalSource(
          path: '/tmp/source.mp4',
          size: 42,
          growing: true,
          fingerprint: '42-1700000000',
        ),
        transportId: 'tus',
        resumeToken: 'token',
        acknowledgedParts: const [0, 1, 3],
        highWaterMark: 24,
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

    test('a whole frame that does not read back is skipped, not torn', () {
      final bytes = codec.encode([
        JournalEntry$Put(
          JournalRecord(
            job: _job(
              'a',
              const TransferState.completed(FakeTransferResult('r')),
            ),
          ),
        ),
        JournalEntry$Put(
          JournalRecord(job: _job('b', const TransferState.queued())),
        ),
      ]);
      // A build that knows no codec for the result kind.
      final read = JournalCodec(const []).decode(bytes);
      expect(read.skipped, 1);
      expect(read.tornBytes, 0);
      expect(read.entries, hasLength(1));
    });

    test('a frame whose checksum fails ends the log there', () {
      final bytes = codec.encode([
        JournalEntry$Put(
          JournalRecord(job: _job('a', const TransferState.queued())),
        ),
        JournalEntry$Put(
          JournalRecord(job: _job('b', const TransferState.queued())),
        ),
      ]);
      // A frame of zeros, as some file systems leave after a kill.
      final zeroed = Uint8List.fromList(bytes)..fillRange(8, 16, 0);
      final read = codec.decode(zeroed);
      expect(read.entries, isEmpty);
      expect(read.tornBytes, bytes.length);
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
