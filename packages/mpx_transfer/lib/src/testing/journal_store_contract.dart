import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/src/diagnostics/journal_op.dart';
import 'package:mpx_transfer/src/job/transfer_id.dart';
import 'package:mpx_transfer/src/job/transfer_job.dart';
import 'package:mpx_transfer/src/job/transfer_state.dart';
import 'package:mpx_transfer/src/journal/journal_codec.dart';
import 'package:mpx_transfer/src/journal/journal_frames.dart';
import 'package:mpx_transfer/src/journal/journal_record.dart';
import 'package:mpx_transfer/src/journal/journal_store.dart';
import 'package:mpx_transfer/src/journal/transfer_journal.dart';
import 'package:mpx_transfer/src/testing/fake_transfer_result.dart';

/// The contract every [JournalStore] meets under the journal: what was
/// written reads back in order, compaction keeps the latest state of each
/// job, a torn tail is dropped, and a kill keeps every state written and
/// loses at most one window of progress.
abstract final class JournalStoreContract {
  /// Runs it as a test group named after [name].
  ///
  /// [storage] is called once per test, inside its `setUp`, for fresh,
  /// empty storage; it answers how to open a store over that storage, and
  /// each call of the answer is a new start over the same bytes; storage
  /// that takes time to make answers a future of it. Clean the storage up
  /// with `addTearDown` inside [storage].
  static void run(
    String name,
    FutureOr<JournalStore Function()> Function() storage,
  ) {
    group('JournalStore contract ($name)', () {
      late JournalStore Function() openStore;
      late RecordingDiagnostics recorder;
      final journals = <TransferJournal>[];

      setUp(() async {
        openStore = await storage();
        recorder = RecordingDiagnostics.install();
      });
      tearDown(() async {
        for (final journal in journals) {
          await journal.close();
        }
        journals.clear();
      });

      // An hour: the window never ends inside a test, so a progress write
      // reaches the store only when the journal is closed.
      Future<TransferJournal> start() async {
        final journal = await TransferJournal.open(
          openStore(),
          retention: const Duration(hours: 24),
          progressInterval: const Duration(hours: 1),
          now: () => _created,
          resultCodecs: const [FakeTransferResult.codec],
        );
        journals.add(journal);
        return journal;
      }

      /// Ends [journal] as a kill would, once what it wrote is flushed.
      Future<void> kill(TransferJournal journal) async {
        await journal.idle;
        journal.abandon();
      }

      test('a store never written reads back no jobs', () async {
        final journal = await start();
        expect(journal.jobs, isEmpty);
      });

      test('what was written reads back in order, the latest of each job, '
          'without what was removed', () async {
        final journal = await start()
          ..writeState(_job('a', const TransferState.queued(total: 10)))
          ..writeState(_job('b', const TransferState.queued()))
          ..writeState(_job('c', const TransferState.queued()))
          ..writeState(_job('a', const TransferState.running(done: 4)))
          ..remove(_id('c'))
          ..writeState(
            _job('b', const TransferState.completed(FakeTransferResult('r'))),
          );
        await kill(journal);

        final again = await start();
        expect(again.jobs, [
          _job('a', const TransferState.running(done: 4)),
          _job('b', const TransferState.completed(FakeTransferResult('r'))),
        ]);
      });

      test('compaction keeps the latest state of each job, in less '
          'room', () async {
        final journal = await start();
        for (var done = 0; done < 50; done++) {
          journal
            ..writeState(_job('a', TransferState.running(done: done)))
            ..writeState(_job('b', TransferState.running(done: done * 2)));
        }
        journal.writeState(
          _job(
            'c',
            const TransferState.paused(reason: PauseReason.user, done: 3),
          ),
        );
        await journal.idle;
        final before = journal.debugSnapshot().bytes;
        await journal.compact();
        expect(journal.debugSnapshot().bytes, lessThan(before));
        expect(journal.debugSnapshot().recordsSinceCompaction, 0);
        await kill(journal);

        final again = await start();
        expect(again.jobs, [
          _job('a', const TransferState.running(done: 49)),
          _job('b', const TransferState.running(done: 98)),
          _job(
            'c',
            const TransferState.paused(reason: PauseReason.user, done: 3),
          ),
        ]);
      });

      test('a torn tail is dropped, and what is written after it reads '
          'back', () async {
        final journal = await start()
          ..writeState(_job('a', const TransferState.queued()))
          ..writeState(_job('b', const TransferState.queued()));
        await kill(journal);

        // A kill in the middle of a write: half of a frame at the end.
        final frame = JournalFrames.encode([
          JournalCodec(const []).encode(
            JournalEntry$Put(
              JournalRecord(job: _job('c', const TransferState.queued())),
            ),
          ),
        ]);
        final torn = frame.length ~/ 2;
        final store = openStore();
        await store.append(Uint8List.sublistView(frame, 0, torn));
        await store.close();

        final again = await start();
        expect(again.jobs.map((job) => job.id), [_id('a'), _id('b')]);
        expect(recorder.whereOp(JournalOp.tornTailDropped), [
          isMpxEvent(fields: {'bytesDropped': torn}),
        ]);
        expect(recorder.errors, isEmpty);

        again.writeState(_job('d', const TransferState.queued()));
        await kill(again);
        final third = await start();
        expect(third.jobs.map((job) => job.id), [_id('a'), _id('b'), _id('d')]);
      });

      test('a kill between a state write and a progress write keeps the '
          'state and loses only the window', () async {
        final journal = await start()
          ..writeState(_job('a', const TransferState.running(done: 10)));
        await journal.idle;
        journal.writeProgress(_job('a', const TransferState.running(done: 50)));
        await kill(journal);

        final again = await start();
        expect(again.jobs, [_job('a', const TransferState.running(done: 10))]);
      });

      test('progress flushed before the end reads back', () async {
        final journal = await start()
          ..writeState(_job('a', const TransferState.running(done: 10)))
          ..writeProgress(_job('a', const TransferState.running(done: 50)));
        await journal.close();

        final again = await start();
        expect(again.jobs, [_job('a', const TransferState.running(done: 50))]);
      });
    });
  }

  static final DateTime _created = DateTime.utc(2026, 11, 27);

  static TransferId _id(String name) => TransferId.parse('u-$name');

  static TransferJob _job(String name, TransferState state) => TransferJob(
    id: _id(name),
    direction: TransferDirection.upload,
    durability: TransferDurability.system,
    state: state,
    createdAt: _created,
    updatedAt: _created,
    tag: 'tag-$name',
  );
}
