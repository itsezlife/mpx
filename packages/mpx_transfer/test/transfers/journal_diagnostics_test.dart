import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/src/journal/journal_store.dart';
import 'package:mpx_transfer/testing.dart';

import '../support.dart';

/// A memory store that refuses reads or appends while told to.
final class _RefusingStore implements JournalStore {
  final MemoryJournalStore memory = MemoryJournalStore();
  bool refuseReads = false;
  bool refuseWrites = false;

  @override
  JournalStoreKind get kind => JournalStoreKind.file;

  @override
  Future<Uint8List> read(JournalBlob blob) {
    if (refuseReads) throw StateError('read refused');
    return memory.read(blob);
  }

  @override
  Future<void> append(Uint8List bytes) {
    if (refuseWrites) throw StateError('write refused');
    return memory.append(bytes);
  }

  @override
  Future<void> replace({required Uint8List snapshot, required Uint8List log}) {
    if (refuseWrites) throw StateError('write refused');
    return memory.replace(snapshot: snapshot, log: log);
  }

  @override
  Future<void> close() => memory.close();

  @override
  String errorCode(Object error) => 'refused';
}

void main() {
  late RecordingDiagnostics recorder;
  late DateTime now;

  setUp(() {
    recorder = RecordingDiagnostics.install();
    now = DateTime.utc(2026, 11, 27);
  });

  test('opened, replayed and compacted at a start after a kill', () async {
    final h = await harness(now: () => now);
    h
      ..addUpload(tag: 'a')
      ..addUpload(tag: 'b')
      ..addDownload(photo);
    await h.settle();
    recorder.clear();
    await h.kill();

    expect(_ofJournal(recorder.whereCategory('journal')).map((e) => e.op), [
      JournalOp.opened,
      JournalOp.replayed,
      JournalOp.compacted,
    ]);
    for (final table in ['reuse']) {
      expect(
        [
          for (final event in recorder.whereCategory('journal'))
            if (event.fields['table'] == table) event.op,
        ],
        [JournalOp.opened, JournalOp.replayed, JournalOp.compacted],
        reason: 'the $table store reports its start as the journal does',
      );
    }
    expect(_ofJournal(recorder.whereOp(JournalOp.opened)), [
      isMpxEvent(
        level: MpxEventLevel.info,
        fields: {'records': 3, 'bytes': greaterThan(0), 'store': 'memory'},
      ),
    ]);
    expect(_ofJournal(recorder.whereOp(JournalOp.replayed)), [
      isMpxEvent(
        level: MpxEventLevel.info,
        fields: {'jobs': 3, 'uploads': 2, 'downloads': 1, 'ms': 0},
      ),
    ]);
    expect(_ofJournal(recorder.whereOp(JournalOp.compacted)), [
      isMpxEvent(
        level: MpxEventLevel.debug,
        fields: {
          'bytesBefore': greaterThan(0),
          'bytesAfter': greaterThan(0),
          'ms': 0,
        },
      ),
    ]);
  });

  test('tornTailDropped after a kill in the middle of a write', () async {
    final memory = MemoryJournalStore();
    var starts = 0;
    final h = await harness(
      now: () => now,
      store: () {
        // The second start finds the first's last write cut short.
        if (++starts == 2) {
          final log = memory.bytesOf(JournalBlob.log);
          unawaited(memory.append(Uint8List.sublistView(log, log.length - 12)));
        }
        return memory;
      },
    );
    final id = h.addUpload();
    await h.settle();
    await h.kill();

    expect(recorder.whereOp(JournalOp.tornTailDropped), [
      isMpxEvent(level: MpxEventLevel.warning, fields: {'bytesDropped': 12}),
    ]);
    expect(h.replayed.single.id, id);
    expect(recorder.errors, isEmpty);
  });

  test('stateWritten for each state change, removed for a cancel', () async {
    final h = await harness(now: () => now);
    final id = h.addUpload();
    h.runner.progress(id, 1);
    h.transfers.pause(id);
    h.transfers.cancel(id);
    await h.settle();

    expect(recorder.whereOp(JournalOp.stateWritten), [
      for (final state in ['queued', 'running', 'paused', 'removed'])
        isMpxEvent(
          level: MpxEventLevel.trace,
          category: 'journal',
          jobId: id,
          fields: {'state': state},
        ),
    ]);
  });

  test('pruned at a start for completed jobs past retention', () async {
    final h = await harness(now: () => now);
    final id = h.addUpload();
    h.runner.complete(id, const FakeTransferResult('ref'));
    await h.settle();
    now = now.add(const Duration(hours: 25));
    await h.kill();

    expect(recorder.whereOp(JournalOp.pruned), [
      isMpxEvent(
        level: MpxEventLevel.debug,
        fields: {'jobs': 1, 'olderThanH': 24},
      ),
    ]);
    expect(h.replayed, isEmpty);
  });

  test('writeFailed for a refused write; the next write rewrites the '
      'journal', () async {
    final store = _RefusingStore();
    final h = await harness(now: () => now, store: () => store);
    store.refuseWrites = true;
    final lost = h.addUpload(tag: 'a');
    await h.settle();

    expect(recorder.whereOp(JournalOp.writeFailed), [
      isMpxEvent(
        level: MpxEventLevel.error,
        category: 'journal',
        jobId: lost,
        fields: {'code': 'refused'},
      ),
    ]);
    expect(
      await jobsOf(h.transfers),
      hasLength(1),
      reason: 'the job stays in memory',
    );

    store.refuseWrites = false;
    recorder.clear();
    final next = h.addUpload(tag: 'b');
    await h.settle();
    expect(recorder.whereOp(JournalOp.compacted), hasLength(1));
    await h.kill();

    expect(h.replayed.map((job) => job.id), [lost, next]);
  });

  test('writeFailed for a refused read; the engine runs in memory', () async {
    final store = _RefusingStore()..refuseReads = true;
    final h = await harness(now: () => now, store: () => store);

    expect(recorder.whereOp(JournalOp.writeFailed), [
      isMpxEvent(level: MpxEventLevel.error, fields: {'code': 'refused'}),
    ]);
    expect(_ofJournal(recorder.whereOp(JournalOp.opened)), [
      isMpxEvent(fields: containsPair('store', 'memory')),
    ]);
    expect(h.transfers.debugSnapshot().journal.store, 'memory');
  });

  test('no event carries the journal path', () async {
    final directory = Directory.systemTemp.createTempSync('mpx_journal_');
    addTearDown(() => directory.delete(recursive: true));
    final transfers = await Transfers.open(
      cache: TransferBytesCache(keyOf: (key) => key.encoded),
      lifecycle: ManualPlaybackLifecycleSource(),
      directory: directory.path,
    );
    await transfers.dispose();

    expect(
      File('${directory.path}/mpx_transfer/journal.log').existsSync(),
      isTrue,
    );
    expect(recorder.whereCategory('journal'), isNotEmpty);
    for (final event in recorder.events) {
      expect('${event.fields}', isNot(contains(directory.path)));
    }
  });

  test(
    'Transfers.open needs a directory on the VM',
    () => expectLater(
      Transfers.open(
        cache: TransferBytesCache(keyOf: (key) => key.encoded),
        lifecycle: ManualPlaybackLifecycleSource(),
      ),
      throwsArgumentError,
    ),
  );

  group('debugSnapshot journal section', () {
    test('store, bytes and records since compaction', () async {
      final h = await harness(now: () => now);
      final fresh = h.transfers.debugSnapshot().journal;
      expect(fresh.store, 'memory');
      expect(fresh.recordsSinceCompaction, 0);
      expect(fresh.lastStateWriteAt, isNull);
      expect(fresh.lastProgressFlushAt, isNull);

      now = now.add(const Duration(seconds: 1));
      h.addUpload();
      h.addUpload();
      await h.settle();
      final written = h.transfers.debugSnapshot().journal;
      expect(written.recordsSinceCompaction, 2);
      expect(written.bytes, greaterThan(fresh.bytes));
      expect(written.lastStateWriteAt, now);
      expect(written.lastProgressFlushAt, isNull);
    });

    test('the last progress flush', () async {
      final h = await harness(now: () => now, progressInterval: Duration.zero);
      final id = h.addUpload();
      h.runner
        ..progress(id, 1)
        ..progress(id, 2);
      await Future<void>.delayed(Duration.zero);
      await h.settle();
      expect(h.transfers.debugSnapshot().journal.lastProgressFlushAt, now);
    });
  });
}

/// The transfer journal's own events: the publish journal's and the reuse
/// table's name their table.
Iterable<MpxEvent> _ofJournal(Iterable<MpxEvent> events) =>
    events.where((event) => !event.fields.containsKey('table'));
