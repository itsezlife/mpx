import 'dart:async';
import 'dart:convert';

import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_transfer/src/diagnostics/journal_op.dart';
import 'package:mpx_transfer/src/journal/journal_store.dart';
import 'package:mpx_transfer/src/journal/record_log.dart';
import 'package:mpx_transfer/src/publish/publish_record.dart';
import 'package:mpx_transfer/src/publish/publish_request.dart';
import 'package:mpx_transfer/src/publish/publish_state.dart';

/// Where publish jobs outlive the process: their records in a store of
/// their own beside the transfer journal's, in the same record log.
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
  PublishJournal._(
    RecordLogRead<_Change> read,
    this._records, {
    required int compactAfter,
  }) {
    _log = RecordLog(
      read,
      codec: const _ChangeCodec(),
      live: () => [for (final record in _records.values) _Change$Put(record)],
      compactAfter: compactAfter,
    );
  }

  /// Reads [store] back, drops the completed jobs older than [retention]
  /// (a job whose aliases are pending stays until they apply) and folds
  /// the rest into a fresh snapshot. A store that cannot be read is
  /// reported (`journal` `writeFailed`, `table: publish`) and replaced by
  /// memory for this run; a record this build cannot read is skipped and
  /// counted (`replayed`, `skipped`).
  static Future<PublishJournal> open(
    JournalStore store, {
    required Duration retention,
    DateTime Function() now = DateTime.now,
    int compactAfter = defaultCompactAfter,
  }) async {
    final openedAt = now();
    final read = await RecordLog.read(
      store,
      codec: const _ChangeCodec(),
      table: _table,
      now: now,
    );
    final records = <PublishJobId, PublishRecord>{};
    for (final change in read.entries) {
      switch (change) {
        case _Change$Put(:final record):
          records[record.id] = record;
        case _Change$Remove(:final id):
          records.remove(id);
      }
    }
    MpxDiagnostics.current.emit(
      MpxEventLevel.info,
      JournalOp.replayed,
      fields: () => {
        'table': _table,
        'jobs': records.length,
        'ms': now().difference(openedAt).inMilliseconds,
        if (read.skipped > 0) 'skipped': read.skipped,
      },
    );
    final time = now();
    records.removeWhere(
      (_, record) =>
          record.end is PublishJobState$Completed &&
          !record.isAliasPending &&
          !time.isBefore(record.updatedAt.add(retention)),
    );
    final journal = PublishJournal._(read, records, compactAfter: compactAfter);
    await journal._log.compact();
    return journal;
  }

  /// How many changes the log takes by default before it is folded.
  static const int defaultCompactAfter = 200;

  static const String _table = 'publish';

  /// How many changes the log takes before it is folded during a run.
  int get compactAfter => _log.compactAfter;

  late final RecordLog<_Change> _log;
  final Map<PublishJobId, PublishRecord> _records;

  /// Every record, in the order the jobs were made.
  Iterable<PublishRecord> get records => _records.values;

  /// Job [id]'s record, or null.
  PublishRecord? record(PublishJobId id) => _records[id];

  /// The store's kind, for a debug panel.
  JournalStoreKind get kind => _log.kind;

  /// Keeps [record] and writes it; completes once that write is done (or
  /// failed, which is reported).
  Future<void> put(PublishRecord record) {
    if (_log.isClosed) return _log.idle;
    _records[record.id] = record;
    return _log.append([_Change$Put(record)], jobId: record.id.value);
  }

  /// Forgets job [id] and writes that; completes once the write is done.
  Future<void> remove(PublishJobId id) {
    if (_log.isClosed || _records.remove(id) == null) return _log.idle;
    return _log.append([_Change$Remove(id)], jobId: id.value);
  }

  /// Completes when every write made so far has finished.
  Future<void> get idle => _log.idle;

  /// Waits for every write and releases the store.
  Future<void> close() => _log.close();

  /// Stops as a killed process would: writes not yet begun are never made.
  void abandon() => _log.abandon();
}

/// One change of the publish journal: what a frame holds.
sealed class _Change {
  const _Change();
}

/// A job's record, replacing any earlier one of its id.
final class _Change$Put extends _Change {
  const _Change$Put(this.record);

  final PublishRecord record;
}

/// A job was forgotten.
final class _Change$Remove extends _Change {
  const _Change$Remove(this.id);

  final PublishJobId id;
}

/// A change as a frame payload: `{"put": record}`, the record in
/// [PublishRecordCodec]'s form, or `{"remove": id}`. Anything else throws
/// a [FormatException]; the log skips that frame and counts it.
final class _ChangeCodec extends Codec<_Change, Object?> {
  const _ChangeCodec();

  @override
  Converter<_Change, Object?> get encoder => const _ChangeEncoder();

  @override
  Converter<Object?, _Change> get decoder => const _ChangeDecoder();
}

final class _ChangeEncoder extends Converter<_Change, Object?> {
  const _ChangeEncoder();

  static const PublishRecordCodec _records = PublishRecordCodec();

  @override
  Object? convert(_Change input) => switch (input) {
    _Change$Put(:final record) => {_Key.put: _records.encode(record)},
    _Change$Remove(:final id) => {_Key.remove: id.value},
  };
}

final class _ChangeDecoder extends Converter<Object?, _Change> {
  const _ChangeDecoder();

  static const PublishRecordCodec _records = PublishRecordCodec();

  @override
  _Change convert(Object? input) => switch (input) {
    {_Key.put: final Map<String, Object?> put} => _Change$Put(
      _records.decode(put),
    ),
    {_Key.remove: final String id} => _Change$Remove(PublishJobId.parse(id)),
    _ => throw FormatException('Expected a publish journal change.', input),
  };
}

/// Field names of a change.
abstract final class _Key {
  static const String put = 'put';
  static const String remove = 'remove';
}
