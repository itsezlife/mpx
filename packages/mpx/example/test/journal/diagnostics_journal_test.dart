/// The diagnostics journal keeps every event in a ring that survives a kill.
///
/// **Seam:** [DiagnosticsJournal] over a [JournalStore] (memory, and the
/// files of the VM), read back through its records and a second journal
/// over the same store.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:l/l.dart';
import 'package:mpx/mpx.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_example/journal/data/diagnostics_journal.dart';
import 'package:mpx_example/journal/data/environment_specific/journal_store_vm.dart';
import 'package:mpx_example/journal/data/journal_store.dart';
import 'package:mpx_example/journal/model/journal_record.dart';

enum _Op implements DiagnosticOp {
  tick,
  failed;

  @override
  String get category => 'transport';
}

MpxEvent _event(
  int n, {
  MpxEventLevel level = MpxEventLevel.info,
  String? jobId,
  String? itemId,
}) => MpxEvent(
  time: DateTime.utc(2026, 11, 27, 12, 0, n),
  level: level,
  op: level == MpxEventLevel.error ? _Op.failed : _Op.tick,
  jobId: jobId,
  itemId: itemId,
  fields: {'n': n},
);

List<Object?> _ns(DiagnosticsJournal journal) => [
  for (final record in journal.records) record.fields['n'],
];

void main() {
  group('in memory', () {
    test('keeps the events in the order they came', () {
      final journal = DiagnosticsJournal.memory();
      addTearDown(journal.dispose);

      for (var n = 0; n < 5; n++) {
        journal.addMpxEvent(_event(n));
      }

      expect(_ns(journal), [0, 1, 2, 3, 4]);
      expect(journal.records.first.category, 'transport');
      expect(journal.records.first.op, 'tick');
      expect(journal.records.first.source, JournalSource.mpx);
    });

    test('drops the oldest events past its cap', () {
      final line = JournalRecord.fromMpxEvent(_event(0)).encode().length + 1;
      // Room for three lines, not four.
      final journal = DiagnosticsJournal.memory(capBytes: line * 3 + 1);
      addTearDown(journal.dispose);

      for (var n = 0; n < 6; n++) {
        journal.addMpxEvent(_event(n));
      }

      expect(_ns(journal), [3, 4, 5]);
      expect(journal.sizeBytes, lessThanOrEqualTo(journal.capBytes));
    });

    test('writes a warning or an error, and the batch before it, before it '
        'returns; the rest waits for the batch', () async {
      final store = MemoryJournalStore();
      final journal = DiagnosticsJournal(
        store: store,
        batchInterval: const Duration(milliseconds: 20),
      );
      addTearDown(journal.dispose);

      journal.addMpxEvent(_event(0));
      expect(store.lines, isEmpty, reason: 'an info waits for the batch');

      journal.addMpxEvent(_event(1, level: MpxEventLevel.error));
      expect(store.lines, hasLength(2));

      journal.addMpxEvent(_event(2, level: MpxEventLevel.warning));
      expect(store.lines, hasLength(3));

      journal.addMpxEvent(_event(3));
      expect(store.lines, hasLength(3));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(store.lines, hasLength(4), reason: 'the batch came due');
    });

    test('restores, after a restart, what the previous run kept, before what '
        'arrived since', () async {
      final store = MemoryJournalStore();
      final first = DiagnosticsJournal(store: store);
      for (var n = 0; n < 3; n++) {
        first.addMpxEvent(_event(n, jobId: 'j7'));
      }
      first.flush();
      // The process dies: no close, no dispose. The torn last line of a
      // write the kill cut short is in the store too.
      store.append(['{"t":1,"l":"in']);

      final second = DiagnosticsJournal(store: store);
      addTearDown(second.dispose);
      second.addMpxEvent(_event(9));
      final restored = await second.restore();

      expect(restored, 3);
      expect(_ns(second), [0, 1, 2, 9]);
      expect(second.records.first.ids, {'jobId': 'j7'});
      expect(
        second.records.first.time.isAtSameMomentAs(
          DateTime.utc(2026, 11, 27, 12),
        ),
        isTrue,
      );
    });

    test('reports its opening with what it restored', () async {
      final store = MemoryJournalStore();
      final first = DiagnosticsJournal(store: store)
        ..addMpxEvent(_event(0))
        ..addMpxEvent(_event(1))
        ..flush();
      addTearDown(first.dispose);
      final recorder = RecordingDiagnostics.install();

      final second = DiagnosticsJournal(store: store);
      addTearDown(second.dispose);
      await second.restore();

      expect(recorder.events, [
        isMpxEvent(
          level: MpxEventLevel.info,
          category: 'journal',
          op: JournalOp.opened,
          fields: allOf(
            containsPair('restored', 2),
            containsPair('skipped', 0),
            containsPair('persistent', false),
          ),
        ),
      ]);
    });

    test('a store that fails is reported once, and the journal goes on in '
        'memory', () {
      final recorder = RecordingDiagnostics.install();
      final journal = DiagnosticsJournal(store: _FailingStore());
      addTearDown(journal.dispose);
      // Routed back into the journal, as the host routes it: the report of
      // the failure must not fail again.
      MpxDiagnostics.current = MpxDiagnostics.onEvent((event) {
        recorder.report(event);
        journal.addMpxEvent(event);
      });

      journal
        ..addMpxEvent(_event(0, level: MpxEventLevel.error))
        ..addMpxEvent(_event(1, level: MpxEventLevel.error));

      expect(recorder.whereOp(JournalOp.storeFailed), [
        isMpxEvent(level: MpxEventLevel.warning, fields: {'lines': 1}),
      ]);
      expect(journal.isPersistent, isFalse);
      expect(journal.length, 3);
    });
  });

  group('sources', () {
    test('MpxDiagnostics.current routed into the journal records the mpx '
        "events with their ids and the bytes cache's as category cache", () {
      final previous = MpxDiagnostics.current;
      addTearDown(() => MpxDiagnostics.current = previous);
      final journal = DiagnosticsJournal.memory();
      addTearDown(journal.dispose);
      MpxDiagnostics.current = journal.mpxDiagnostics;

      MpxDiagnostics.current.emit(
        MpxEventLevel.info,
        BindingOp.trackedDownload,
        jobId: 'j1',
        itemId: 'i1',
        mediaKey: const MediaKey.remote('still'),
        tag: 'album',
        fields: () => {'origin': 'user'},
      );
      CacheDiagnosticsBridge.policy.report(
        const BytesLogEvent(
          level: BytesLogLevel.warning,
          message:
              'BytesResolver background revalidation failed for '
              'https://cdn.example.com/u/42/photo.jpg?token=secret',
          op: BytesLogOp.revalidateBackground,
        ),
      );

      final [binding, cache] = journal.records.toList();
      expect(binding.category, 'binding');
      expect(binding.ids, {
        'jobId': 'j1',
        'itemId': 'i1',
        'mediaKey': const MediaKey.remote('still').encoded,
        'tag': 'album',
      });
      expect(cache.category, 'cache');
      expect(cache.level, MpxEventLevel.warning);
      expect(cache.encode(), isNot(contains('photo')));
      expect(cache.encode(), isNot(contains('secret')));
    });

    test('an error keeps its text with URLs cut to their host', () {
      final journal = DiagnosticsJournal.memory();
      addTearDown(journal.dispose);

      journal.mpxDiagnostics.emit(
        MpxEventLevel.error,
        _Op.failed,
        error: 'GET https://example.com/a/b?q=1 failed: connection closed',
      );

      final [record] = journal.records.toList();
      expect(record.error, contains('https://example.com'));
      expect(record.error, isNot(contains('/a/b')));
      expect(record.error, isNot(contains('q=1')));
    });

    test("the app's own log: level mapped, URLs cut, restored from a line", () {
      final journal = DiagnosticsJournal.memory();
      addTearDown(journal.dispose);

      journal.addLog(
        LogMessageError(
          message: 'Fetch of https://example.com/u/1?token=x failed',
          timestamp: DateTime.utc(2026, 11, 27),
          level: const LogLevel.error(),
          stackTrace: StackTrace.fromString('#0 main'),
        ),
      );

      final [record] = journal.records.toList();
      expect(record.source, JournalSource.app);
      expect(record.category, 'app');
      expect(record.level, MpxEventLevel.error);
      expect(record.message, 'Fetch of https://example.com failed');
      expect(record.stackTrace, '#0 main');
      expect(JournalRecord.tryParse(record.encode())?.message, record.message);
    });
  });

  group('on disk', () {
    late Directory directory;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('journal_test');
      addTearDown(() => directory.delete(recursive: true));
    });

    test('a warning is in the file when the call returns, and a journal over '
        'the same folder restores it', () async {
      final store = await FileJournalStore.open(directory, capBytes: 1 << 20);
      final first = DiagnosticsJournal(store: store)
        ..addMpxEvent(_event(0))
        ..addMpxEvent(_event(1, level: MpxEventLevel.warning));

      final written = File('${directory.path}/journal.1.jsonl');
      expect(written.readAsLinesSync(), hasLength(2));
      // Killed: the store is never closed.
      first.dispose();

      final again = DiagnosticsJournal(
        store: await FileJournalStore.open(directory, capBytes: 1 << 20),
      );
      addTearDown(again.dispose);
      await again.restore();

      expect(_ns(again), [0, 1]);
      expect(again.isPersistent, isTrue);
    });

    test('the files hold about the cap: the oldest lines go first', () async {
      final line = JournalRecord.fromMpxEvent(_event(10)).encode().length + 1;
      final cap = line * 8;
      final store = await FileJournalStore.open(directory, capBytes: cap);
      final journal = DiagnosticsJournal(store: store, capBytes: cap);
      for (var n = 10; n < 40; n++) {
        journal
          ..addMpxEvent(_event(n))
          ..flush();
      }
      await journal.close();
      journal.dispose();

      final kept = await (await FileJournalStore.open(
        directory,
        capBytes: cap,
      )).read();
      final size = kept.fold(0, (sum, line) => sum + line.length + 1);
      expect(size, lessThanOrEqualTo(cap));
      expect(kept, isNotEmpty);
      expect(JournalRecord.tryParse(kept.last)?.fields['n'], 39);
      expect(JournalRecord.tryParse(kept.first)?.fields['n'], greaterThan(10));
    });
  });
}

final class _FailingStore implements JournalStore {
  @override
  bool get isPersistent => true;

  @override
  Future<List<String>> read() async => const [];

  @override
  void append(List<String> lines) =>
      throw const FileSystemException('No space left on device');

  @override
  Future<void> close() async {}
}
