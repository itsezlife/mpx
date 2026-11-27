import 'dart:async';
import 'dart:collection' show Queue;
import 'dart:convert';

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:l/l.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_example/journal/data/journal_store.dart';
import 'package:mpx_example/journal/model/journal_record.dart';

/// What the journal reports about itself.
enum JournalOp implements DiagnosticOp {
  /// The journal restored what the previous run kept and records from now.
  opened,

  /// A file of the journal went out through the share sheet.
  exported,

  /// Sharing the export failed.
  exportFailed,

  /// The store refused a write; the journal keeps recording in memory only.
  storeFailed;

  @override
  String get category => 'journal';
}

/// Every diagnostics event of the process, newest last, in a ring of
/// [capBytes] kept in memory and in a [JournalStore], so the minutes before a
/// kill are there at the next start.
///
/// The host routes the policies into it once at start ([mpxDiagnostics], and
/// [addLog] for the app's own log). Lines go to the store in batches, at most
/// [batchInterval] after they arrive; a warning or an error is written with
/// everything before it before [add] returns, since it is the event a kill
/// right after would otherwise take with it.
///
/// It never reports from [add]: its own events go through
/// `MpxDiagnostics.current`, which routes back into [add], so a report from
/// there would loop.
final class DiagnosticsJournal with ChangeNotifier {
  /// A journal over [store], empty until [restore].
  DiagnosticsJournal({
    required JournalStore store,
    this.capBytes = defaultCapBytes,
    this.batchInterval = const Duration(seconds: 1),
  }) : _store = store;

  /// A journal over memory alone, for a host that keeps no file (tests).
  DiagnosticsJournal.memory({int capBytes = defaultCapBytes})
    : this(store: MemoryJournalStore(), capBytes: capBytes);

  /// The default ring: 20 MiB, about a day of a busy session's events.
  static const defaultCapBytes = 20 * 1024 * 1024;

  /// The most the records take, as the store's lines; the oldest go past it.
  final int capBytes;

  /// The longest a line waits before it is written.
  final Duration batchInterval;

  final JournalStore _store;
  final Queue<(JournalRecord, int)> _records = Queue();
  final List<String> _$pending = [];
  Timer? _$batch;
  int _$bytes = 0;
  bool _$restored = false;
  bool _$storeFailed = false;
  bool _$disposed = false;

  /// The records, oldest first.
  Iterable<JournalRecord> get records => _records.map((entry) => entry.$1);

  /// How many records there are.
  int get length => _records.length;

  /// The records' size as lines, in bytes.
  int get sizeBytes => _$bytes;

  /// Whether the records outlive the process.
  bool get isPersistent => _store.isPersistent && !_$storeFailed;

  /// The mpx packages' policy, into this journal: every event, the bytes
  /// cache's (category `cache`) included.
  MpxDiagnostics get mpxDiagnostics => MpxDiagnostics.onEvent(addMpxEvent);

  /// Records an mpx package's [event].
  void addMpxEvent(MpxEvent event) => add(JournalRecord.fromMpxEvent(event));

  /// Records a line of the app's own log.
  void addLog(LogMessage log) => add(JournalRecord.fromLog(log));

  /// Records [record], dropping the oldest past [capBytes].
  void add(JournalRecord record) {
    if (_$disposed) return;
    final line = record.encode();
    _push(record, line);
    _$pending.add(line);
    if (record.level.index >= MpxEventLevel.warning.index) {
      flush();
    } else {
      _$batch ??= Timer(batchInterval, flush);
    }
    notifyListeners();
  }

  /// Reads what the previous runs kept into the journal, before what arrived
  /// since it was made, then reports [JournalOp.opened] with the count.
  ///
  /// Lines that do not read as records (the torn line of a kill mid-write)
  /// are skipped and counted. Once only; a second call restores nothing.
  Future<int> restore() async {
    if (_$restored) return 0;
    _$restored = true;
    final lines = await _store.read();
    final live = List.of(_records);
    _records.clear();
    _$bytes = 0;
    var restored = 0;
    var skipped = 0;
    for (final line in lines) {
      switch (JournalRecord.tryParse(line)) {
        case final record?:
          _push(record, line);
          restored++;
        case null:
          skipped++;
      }
    }
    for (final (record, bytes) in live) {
      _records.add((record, bytes));
      _$bytes += bytes;
      _trim();
    }
    if (!_$disposed) notifyListeners();
    MpxDiagnostics.current.emit(
      MpxEventLevel.info,
      JournalOp.opened,
      fields: () => {
        'restored': restored,
        'skipped': skipped,
        'kept': _records.length,
        'bytes': _$bytes,
        'capBytes': capBytes,
        'persistent': isPersistent,
      },
    );
    return restored;
  }

  /// Writes the lines waiting for the next batch now.
  void flush() {
    _$batch?.cancel();
    _$batch = null;
    if (_$pending.isEmpty) return;
    final lines = List.of(_$pending);
    _$pending.clear();
    if (_$storeFailed) return;
    try {
      _store.append(lines);
    } on Object catch (error, stackTrace) {
      // Switched off before the report: the report is a warning, which
      // flushes, and a store that failed once would fail it again.
      _$storeFailed = true;
      MpxDiagnostics.current.emit(
        MpxEventLevel.warning,
        JournalOp.storeFailed,
        fields: () => {'lines': lines.length},
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Writes what is waiting and releases the store.
  Future<void> close() async {
    flush();
    await _store.close();
  }

  void _push(JournalRecord record, String line) {
    // The line and its newline, as the store holds it.
    final bytes = utf8.encode(line).length + 1;
    _records.add((record, bytes));
    _$bytes += bytes;
    _trim();
  }

  void _trim() {
    while (_$bytes > capBytes && _records.length > 1) {
      _$bytes -= _records.removeFirst().$2;
    }
  }

  @override
  void dispose() {
    if (_$disposed) return;
    flush();
    _$disposed = true;
    unawaited(_store.close());
    super.dispose();
  }
}
