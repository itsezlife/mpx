import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/src/journal/journal_frames.dart';
import 'package:mpx_transfer/src/journal/journal_store.dart';
import 'package:mpx_transfer/src/publish/publish_journal.dart';
import 'package:mpx_transfer/testing.dart' show FakeUploadTransport;

import 'stored_format_fixtures.dart';

final DateTime _t0 = DateTime.utc(2026, 11, 27, 10);

Future<PublishJournal> _publish(JournalStore store) => PublishJournal.open(
  store,
  retention: const Duration(hours: 24),
  now: () => _t0,
);

Future<ReuseTable> _reuse(JournalStore store) =>
    ReuseTable.open(store, now: () => _t0);

final FakeUploadTransport _tus = FakeUploadTransport(id: 'tus');

void main() {
  late RecordingDiagnostics recorder;

  setUp(() => recorder = RecordingDiagnostics.install());

  group('every store', () {
    test('the publish journal skips a record it cannot read and reports '
        'it as the transfer journal does', () async {
      final store = MemoryJournalStore();
      await store.replace(
        snapshot: Uint8List(0),
        log: Uint8List.fromList([
          ...publishCompactedFixture.snapshot,
          ...JournalFrames.encode([
            {
              'put': {'v': 99},
            },
          ]),
        ]),
      );
      final journal = await _publish(store);
      addTearDown(journal.close);
      expect(journal.records.map((record) => record.id.value), ['p-01']);
      expect(recorder.whereOp(JournalOp.replayed), [
        isMpxEvent(
          fields: {'table': 'publish', 'jobs': 1, 'ms': 0, 'skipped': 1},
        ),
      ]);
    });

    test('the reuse table skips a change it cannot read and reports it as '
        'the transfer journal does', () async {
      final store = MemoryJournalStore();
      await store.replace(
        snapshot: reuseCompactedFixture.snapshot,
        log: JournalFrames.encode([
          {
            'put': {'transport': 'tus'},
          },
        ]),
      );
      final table = await _reuse(store);
      addTearDown(table.close);
      expect(table.debugSnapshot().entries, 2);
      expect(recorder.whereOp(JournalOp.replayed), [
        isMpxEvent(
          fields: {'table': 'reuse', 'entries': 2, 'ms': 0, 'skipped': 1},
        ),
      ]);
    });

    test('a publish log older than its snapshot is not replayed over it, '
        'as after a kill inside a compaction', () async {
      final store = MemoryJournalStore();
      final journal = await _publish(store);
      final record = (await _publish(
        await _withBlobs(publishCompactedFixture),
      )).records.single;
      await journal.put(record.copyWith(attempts: 1));
      final staleLog = store.bytesOf(JournalBlob.log);
      await journal.put(record.copyWith(attempts: 7));
      await journal.close();
      final folded = await _publish(store);
      await folded.close();
      await store.replace(
        snapshot: store.bytesOf(JournalBlob.snapshot),
        log: staleLog,
      );
      final again = await _publish(store);
      addTearDown(again.close);
      expect(again.records.single.attempts, 7);
    });

    test(
      'a reuse log older than its snapshot is not replayed over it',
      () async {
        final store = MemoryJournalStore();
        final table = await _reuse(store);
        table.store(ReuseKey.host('a'), _tus, file: RemoteRef('f-old'));
        await table.idle;
        final staleLog = store.bytesOf(JournalBlob.log);
        table.invalidate(ReuseKey.host('a'), _tus);
        await table.close();
        await (await _reuse(store)).close();
        await store.replace(
          snapshot: store.bytesOf(JournalBlob.snapshot),
          log: staleLog,
        );
        final again = await _reuse(store);
        addTearDown(again.close);
        expect(await again.lookup(ReuseKey.host('a'), _tus), isNull);
      },
    );

    test('the reuse table ignores a change after its close', () async {
      final store = MemoryJournalStore();
      final table = await _reuse(store);
      await table.close();
      table.store(ReuseKey.host('a'), _tus, file: RemoteRef('f'));
      await table.idle;
      final again = await _reuse(store);
      addTearDown(again.close);
      expect(again.debugSnapshot().entries, 0);
    });
  });
}

Future<MemoryJournalStore> _withBlobs(StoredBlobs blobs) async {
  final store = MemoryJournalStore();
  await store.replace(snapshot: blobs.snapshot, log: blobs.log);
  return store;
}
