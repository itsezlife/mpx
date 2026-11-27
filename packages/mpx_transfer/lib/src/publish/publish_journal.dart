import 'dart:async';
import 'dart:typed_data';

import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_transfer/src/diagnostics/journal_op.dart';
import 'package:mpx_transfer/src/journal/journal_frames.dart';
import 'package:mpx_transfer/src/journal/journal_store.dart';
import 'package:mpx_transfer/src/publish/publish_record.dart';
import 'package:mpx_transfer/src/publish/publish_request.dart';
import 'package:mpx_transfer/src/publish/publish_state.dart';

/// Where publish jobs outlive the process: their records in a store of
/// their own beside the transfer journal's, in the same frame format.
///
/// Kept apart from the transfer journal because that one is keyed by
/// transfer id and holds transfer jobs; a publish job owns several of
/// those. Each change is appended and flushed at once ([put] answers when
/// its write is done, so a caller can order a later write in another store
/// after it); the records are folded into a fresh snapshot at each start
/// and every [compactAfter] changes. A write that fails leaves memory as it
/// is and makes the next one rewrite every record.
///
/// Internal to the package.
final class PublishJournal {
  PublishJournal._(this._store, this._records, this.compactAfter);

  /// Reads [store] back, drops the completed jobs older than [retention]
  /// and folds the rest into a fresh snapshot. A store that cannot be read
  /// is reported (`journal` `writeFailed`, `table: publish`) and replaced by
  /// memory for this run.
  static Future<PublishJournal> open(
    JournalStore store, {
    required Duration retention,
    DateTime Function() now = DateTime.now,
    int compactAfter = defaultCompactAfter,
  }) async {
    var source = store;
    final records = <PublishJobId, PublishRecord>{};
    try {
      final snapshot = await source.read(JournalBlob.snapshot);
      final log = await source.read(JournalBlob.log);
      for (final payload in [
        ...JournalFrames.decode(snapshot).payloads,
        ...JournalFrames.decode(log).payloads,
      ]) {
        _apply(records, payload);
      }
    } on Object catch (error, stackTrace) {
      _emitWriteFailed(source, error, stackTrace);
      source = MemoryJournalStore();
      records.clear();
    }
    final time = now();
    records.removeWhere(
      (_, record) =>
          record.end is PublishJobState$Completed &&
          !time.isBefore(record.updatedAt.add(retention)),
    );
    final journal = PublishJournal._(source, records, compactAfter);
    await journal._compact();
    return journal;
  }

  /// How many changes the log takes by default before it is folded.
  static const int defaultCompactAfter = 200;

  /// How many changes the log takes before it is folded during a run.
  final int compactAfter;

  final JournalStore _store;
  final Map<PublishJobId, PublishRecord> _records;

  int _changesSinceCompaction = 0;
  bool _rewrite = false;
  bool _closed = false;
  bool _abandoned = false;
  Future<void> _tail = Future.value();

  /// Every record, in the order the jobs were made.
  Iterable<PublishRecord> get records => _records.values;

  /// Job [id]'s record, or null.
  PublishRecord? record(PublishJobId id) => _records[id];

  /// The store's kind, for a debug panel.
  JournalStoreKind get kind => _store.kind;

  /// Keeps [record] and writes it; completes once that write is done (or
  /// failed, which is reported).
  Future<void> put(PublishRecord record) {
    _records[record.id] = record;
    return _write({'put': PublishRecordCodec.encode(record)});
  }

  /// Completes when every write made so far has finished.
  Future<void> get idle => _tail;

  /// Waits for every write and releases the store.
  Future<void> close() async {
    if (_closed) return _tail;
    _closed = true;
    await _tail;
    await _store.close();
  }

  /// Stops as a killed process would: writes not yet begun are never made.
  void abandon() {
    if (_closed) return;
    _closed = true;
    _abandoned = true;
    unawaited(_tail.then((_) => _store.close()));
  }

  Future<void> _write(Map<String, Object?> change) {
    if (_closed) return _tail;
    final bytes = JournalFrames.encode([change]);
    return _tail = _tail.then((_) async {
      if (_abandoned) return;
      if (_rewrite) {
        await _compact();
        return;
      }
      try {
        await _store.append(bytes);
      } on Object catch (error, stackTrace) {
        _rewrite = true;
        _emitWriteFailed(_store, error, stackTrace);
        return;
      }
      if (++_changesSinceCompaction >= compactAfter) await _compact();
    });
  }

  Future<void> _compact() async {
    final snapshot = JournalFrames.encode([
      for (final record in _records.values)
        {'put': PublishRecordCodec.encode(record)},
    ]);
    try {
      await _store.replace(snapshot: snapshot, log: Uint8List(0));
    } on Object catch (error, stackTrace) {
      _rewrite = true;
      _emitWriteFailed(_store, error, stackTrace);
      return;
    }
    _changesSinceCompaction = 0;
    _rewrite = false;
  }

  /// Applies one change read back; a record this build cannot read is
  /// skipped, as the transfer journal skips one.
  static void _apply(
    Map<PublishJobId, PublishRecord> records,
    Object? payload,
  ) {
    try {
      switch (payload) {
        case {'put': final Map<String, Object?> put}:
          final record = PublishRecordCodec.decode(put);
          records[record.id] = record;
        case {'remove': final String id}:
          records.remove(PublishJobId.parse(id));
      }
    } on Object {
      // A record of a newer version, or one cut short: skipped.
    }
  }

  static void _emitWriteFailed(
    JournalStore store,
    Object error,
    StackTrace stackTrace,
  ) => MpxDiagnostics.current.emit(
    MpxEventLevel.error,
    JournalOp.writeFailed,
    // The error itself stays out: a file system error names its path.
    fields: () => {'code': store.errorCode(error), 'table': 'publish'},
    stackTrace: stackTrace,
  );
}
