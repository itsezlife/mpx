import 'dart:async';

import 'package:meta/meta.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_transfer/src/diagnostics/journal_op.dart';
import 'package:mpx_transfer/src/diagnostics/transfers_debug_snapshot.dart';
import 'package:mpx_transfer/src/job/transfer_id.dart';
import 'package:mpx_transfer/src/job/transfer_job.dart';
import 'package:mpx_transfer/src/job/transfer_state.dart';
import 'package:mpx_transfer/src/journal/journal_codec.dart';
import 'package:mpx_transfer/src/journal/journal_record.dart';
import 'package:mpx_transfer/src/journal/journal_store.dart';
import 'package:mpx_transfer/src/journal/record_log.dart';

/// The engine's jobs, kept in memory for the queries and written to a
/// [JournalStore] so that a start after any kill reads them back.
///
/// Memory is the source the queries read; the store follows it. A state
/// change is written and flushed at once; progress is batched, at most one
/// write per [progressInterval], so a kill loses at most one window of
/// progress and never a state. Writes run one at a time, in the order they
/// were made, on the calling isolate with async IO.
///
/// Each start folds what it read into a fresh snapshot, which also cuts a
/// torn tail off the log before anything is appended after it; during the
/// run the log is folded again every [compactAfter] records. A write that
/// fails leaves memory as it is and makes the next write rewrite the
/// whole journal, so no record is lost behind a broken frame.
///
/// Internal to the package.
final class TransferJournal {
  TransferJournal._({
    required RecordLogRead<JournalEntry> read,
    required JournalCodec codec,
    required Map<TransferId, JournalRecord> records,
    required this.progressInterval,
    required int compactAfter,
    required DateTime Function() now,
    required DateTime openedAt,
  }) : _records = records,
       _now = now,
       _openedAt = openedAt {
    _log = RecordLog(
      read,
      codec: codec,
      live: () => [
        for (final record in _records.values) JournalEntry$Put(record),
      ],
      compactAfter: compactAfter,
      // The snapshot holds the batched progress too.
      beforeCompaction: _progressPending.clear,
    );
  }

  /// Reads [store] back, rebuilds the jobs, forgets completed jobs past
  /// [retention] and folds the result into a fresh snapshot.
  ///
  /// A store that cannot be read is reported and replaced by memory for
  /// this run, so the engine starts with no jobs rather than not at all;
  /// what the store holds is left for the next start.
  static Future<TransferJournal> open(
    JournalStore store, {
    required Duration retention,
    DateTime Function() now = DateTime.now,
    Duration progressInterval = defaultProgressInterval,
    int compactAfter = defaultCompactAfter,
    Iterable<TransferResultCodec> resultCodecs = const [],
  }) async {
    final codec = JournalCodec(resultCodecs);
    final openedAt = now();
    final read = await RecordLog.read(store, codec: codec, now: now);
    final records = <TransferId, JournalRecord>{};
    for (final entry in read.entries) {
      switch (entry) {
        case JournalEntry$Put(:final record):
          records[record.job.id] = record;
        case JournalEntry$Remove(:final id):
          records.remove(id);
      }
    }
    final jobs = records.values.map((record) => record.job).toList();
    MpxDiagnostics.current.emit(
      MpxEventLevel.info,
      JournalOp.replayed,
      fields: () => {
        'jobs': jobs.length,
        'uploads': jobs
            .where((job) => job.direction == TransferDirection.upload)
            .length,
        'downloads': jobs
            .where((job) => job.direction == TransferDirection.download)
            .length,
        'ms': now().difference(openedAt).inMilliseconds,
        if (read.skipped > 0) 'skipped': read.skipped,
      },
    );

    final journal = TransferJournal._(
      read: read,
      codec: codec,
      records: records,
      progressInterval: progressInterval,
      compactAfter: compactAfter,
      now: now,
      openedAt: openedAt,
    );
    journal._expired(retention).forEach(records.remove);
    await journal._log.compact();
    return journal;
  }

  /// How often progress is written at most by default: every 250 ms.
  static const Duration defaultProgressInterval = Duration(milliseconds: 250);

  /// How many records the log takes by default before it is folded into
  /// the snapshot during a run.
  static const int defaultCompactAfter = 1000;

  /// The shortest time between two progress writes.
  final Duration progressInterval;

  /// How many records the log takes before it is folded during a run.
  int get compactAfter => _log.compactAfter;

  late final RecordLog<JournalEntry> _log;
  final Map<TransferId, JournalRecord> _records;
  final DateTime Function() _now;
  final DateTime _openedAt;

  final Set<TransferId> _progressPending = {};
  Timer? _progressTimer;
  DateTime? _lastStateWriteAt;
  DateTime? _lastProgressFlushAt;

  // --- Reads -----------------------------------------------------------------

  /// Every job kept, in the order they were first written.
  Iterable<TransferJob> get jobs => _records.values.map((r) => r.job);

  /// Job [id], or null when none is kept.
  TransferJob? job(TransferId id) => _records[id]?.job;

  /// Job [id]'s whole record, or null when none is kept.
  JournalRecord? record(TransferId id) => _records[id];

  /// Every record kept, in the order their jobs were first written.
  Iterable<JournalRecord> get records => _records.values;

  /// What the storage is.
  JournalStoreKind get kind => _log.kind;

  /// The journal's state now, for a debug panel.
  JournalDebugSnapshot debugSnapshot() => JournalDebugSnapshot(
    store: _log.kind.name,
    bytes: _log.bytes,
    recordsSinceCompaction: _log.sinceCompaction,
    lastStateWriteAt: _lastStateWriteAt,
    lastProgressFlushAt: _lastProgressFlushAt,
  );

  /// Completes when every write made so far has finished. A progress
  /// batch still waiting for its window is not one of them.
  @internal
  Future<void> get idle => _log.idle;

  // --- Writes ----------------------------------------------------------------

  /// Keeps [job] and writes it at once: a new job or a change of state.
  void writeState(TransferJob job) {
    if (_log.isClosed) return;
    final record = _put(job);
    _progressPending.remove(job.id);
    _log.append(
      [JournalEntry$Put(record)],
      jobId: job.id,
      onWritten: (_) {
        _lastStateWriteAt = _now();
        MpxDiagnostics.current.emit(
          MpxEventLevel.trace,
          JournalOp.stateWritten,
          jobId: job.id,
          fields: () => {'state': _stateName(job.state)},
        );
      },
    );
  }

  /// Keeps [job], whose bytes moved on in the same state, and writes it
  /// with the next progress batch.
  void writeProgress(TransferJob job) {
    if (_log.isClosed) return;
    if (!_records.containsKey(job.id)) return writeState(job);
    _put(job);
    _progressPending.add(job.id);
    _progressTimer ??= Timer(progressInterval, _flushProgress);
  }

  /// Keeps [record], a job not yet written, in memory only: the job's
  /// first [writeState] writes it whole. A new upload's facts ride in with
  /// its first state this way, so no write holds the job without them.
  void stage(JournalRecord record) {
    if (_log.isClosed) return;
    assert(
      !_records.containsKey(record.job.id),
      'Only a job not yet kept is staged.',
    );
    _records[record.job.id] = record;
  }

  /// Keeps [handle], the OS envelope job [id] runs in, and writes the job
  /// at once, so a restart after any kill matches the envelope the native
  /// part still holds to it.
  void writeEnvelopeHandle(TransferId id, String handle) {
    if (_log.isClosed) return;
    final record = _records[id];
    if (record == null || record.envelopeHandle == handle) return;
    _records[id] = record.copyWith(envelopeHandle: handle);
    writeState(record.job);
  }

  /// Changes job [id]'s upload facts in memory with [change]. They reach
  /// storage with the job's next write: the progress or the state the
  /// caller reports right after, so an acknowledged part is written with
  /// its progress window and a kill loses at most that window.
  void amendUpload(
    TransferId id,
    JournalUpload Function(JournalUpload) change,
  ) {
    if (_log.isClosed) return;
    final record = _records[id];
    final upload = record?.upload;
    if (record == null || upload == null) return;
    _records[id] = record.copyWith(upload: change(upload));
  }

  /// Changes job [id]'s upload facts with [change] and writes the job at
  /// once: a fact a kill must not lose, as the remote end's finish answer.
  void writeUpload(
    TransferId id,
    JournalUpload Function(JournalUpload) change,
  ) {
    amendUpload(id, change);
    if (_records[id] case final record?) writeState(record.job);
  }

  /// Forgets job [id] and writes that at once.
  void remove(TransferId id) {
    if (_log.isClosed || _records.remove(id) == null) return;
    _progressPending.remove(id);
    _log.append(
      [JournalEntry$Remove(id)],
      jobId: id,
      onWritten: (_) {
        _lastStateWriteAt = _now();
        MpxDiagnostics.current.emit(
          MpxEventLevel.trace,
          JournalOp.stateWritten,
          jobId: id,
          fields: () => {'state': 'removed'},
        );
      },
    );
  }

  /// Forgets the completed jobs past [retention]; answers their ids.
  List<TransferId> prune(Duration retention) {
    final expired = _expired(retention);
    expired.forEach(remove);
    return expired;
  }

  /// Folds the log into a fresh snapshot after the writes made so far.
  Future<void> compact() => _log.compact();

  /// Writes the progress still batched, waits for every write, and releases
  /// the store. Writes after this are ignored.
  Future<void> close() {
    if (!_log.isClosed) _flushProgress();
    return _log.close();
  }

  /// Stops at this point as a killed process would: progress still batched
  /// is lost, writes not yet begun are never made, and a write under way
  /// finishes or not as the store makes it.
  @internal
  void abandon() {
    _progressTimer?.cancel();
    _progressTimer = null;
    _progressPending.clear();
    _log.abandon();
  }

  // --- Internals -------------------------------------------------------------

  JournalRecord _put(TransferJob job) {
    final previous = _records[job.id];
    final record = previous == null
        ? JournalRecord(job: job)
        : previous.copyWith(job: job);
    return _records[job.id] = job.state is TransferState$Running
        ? record.copyWith(lastProgressAt: job.updatedAt)
        : record;
  }

  List<TransferId> _expired(Duration retention) {
    final now = _now();
    final expired = [
      for (final record in _records.values)
        if (record.job.state is TransferState$Completed &&
            !now.isBefore(record.job.updatedAt.add(retention)))
          record.job.id,
    ];
    if (expired.isNotEmpty) {
      MpxDiagnostics.current.emit(
        MpxEventLevel.debug,
        JournalOp.pruned,
        fields: () => {'jobs': expired.length, 'olderThanH': retention.inHours},
      );
    }
    return expired;
  }

  void _flushProgress() {
    _progressTimer?.cancel();
    _progressTimer = null;
    if (_log.isClosed || _progressPending.isEmpty) return;
    final entries = [
      for (final id in _progressPending)
        if (_records[id] case final record?) JournalEntry$Put(record),
    ];
    _progressPending.clear();
    _log.append(
      entries,
      trace: JournalOp.progressFlushed,
      onWritten: (bytes) {
        final now = _now();
        final since = now.difference(_lastProgressFlushAt ?? _openedAt);
        _lastProgressFlushAt = now;
        MpxDiagnostics.current.emit(
          MpxEventLevel.trace,
          JournalOp.progressFlushed,
          fields: () => {
            'jobs': entries.length,
            'bytes': bytes,
            'sinceLastMs': since.inMilliseconds,
          },
        );
      },
    );
  }

  static String _stateName(TransferState state) => switch (state) {
    TransferState$Queued() => 'queued',
    TransferState$Running() => 'running',
    TransferState$Paused() => 'paused',
    TransferState$Failed() => 'failed',
    TransferState$Completed() => 'completed',
  };
}
