import 'dart:async';
import 'dart:typed_data';

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
    required JournalStore store,
    required JournalCodec codec,
    required Map<TransferId, JournalRecord> records,
    required int generation,
    required int bytes,
    required this.progressInterval,
    required this.compactAfter,
    required DateTime Function() now,
    required DateTime openedAt,
  }) : _store = store,
       _codec = codec,
       _records = records,
       _generation = generation,
       _bytes = bytes,
       _now = now,
       _openedAt = openedAt;

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
    var source = store;
    Uint8List snapshotBytes;
    Uint8List logBytes;
    try {
      snapshotBytes = await source.read(JournalBlob.snapshot);
      logBytes = await source.read(JournalBlob.log);
    } on Object catch (error, stackTrace) {
      _emitWriteFailed(source, error, stackTrace);
      source = MemoryJournalStore();
      snapshotBytes = logBytes = Uint8List(0);
    }

    final snapshot = codec.decode(snapshotBytes);
    final log = codec.decode(logBytes);
    final generation = switch (snapshot.entries.firstOrNull) {
      JournalEntry$Header(:final generation) => generation,
      _ => 0,
    };
    // A log whose generation is not the snapshot's was written before the
    // snapshot replaced it: a kill fell between the two steps of a
    // compaction, and the snapshot already holds what the log says.
    final logEntries = switch (log.entries.firstOrNull) {
      JournalEntry$Header(generation: final g) when g == generation =>
        log.entries,
      _ => const <JournalEntry>[],
    };
    final read = [...snapshot.entries, ...logEntries];
    MpxDiagnostics.current.emit(
      MpxEventLevel.info,
      JournalOp.opened,
      fields: () => {
        'records': read.where((e) => e is! JournalEntry$Header).length,
        'bytes': snapshotBytes.length + logBytes.length,
        'store': source.kind.name,
      },
    );
    final torn = snapshot.tornBytes + log.tornBytes;
    if (torn > 0) {
      MpxDiagnostics.current.emit(
        MpxEventLevel.warning,
        JournalOp.tornTailDropped,
        fields: () => {'bytesDropped': torn},
      );
    }

    final records = <TransferId, JournalRecord>{};
    for (final entry in read) {
      switch (entry) {
        case JournalEntry$Header():
          break;
        case JournalEntry$Put(:final record):
          records[record.job.id] = record;
        case JournalEntry$Remove(:final id):
          records.remove(id);
      }
    }
    final skipped = snapshot.skipped + log.skipped;
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
        if (skipped > 0) 'skipped': skipped,
      },
    );

    final journal = TransferJournal._(
      store: source,
      codec: codec,
      records: records,
      generation: generation,
      bytes: snapshotBytes.length + logBytes.length,
      progressInterval: progressInterval,
      compactAfter: compactAfter,
      now: now,
      openedAt: openedAt,
    );
    journal._expired(retention).forEach(records.remove);
    await journal._compact();
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
  final int compactAfter;

  final JournalStore _store;
  final JournalCodec _codec;
  final Map<TransferId, JournalRecord> _records;
  final DateTime Function() _now;
  final DateTime _openedAt;

  int _generation;
  int _bytes;
  int _recordsSinceCompaction = 0;
  bool _rewrite = false;
  bool _closed = false;
  bool _abandoned = false;

  final Set<TransferId> _progressPending = {};
  Timer? _progressTimer;
  DateTime? _lastStateWriteAt;
  DateTime? _lastProgressFlushAt;

  Future<void> _tail = Future.value();

  // --- Reads -----------------------------------------------------------------

  /// Every job kept, in the order they were first written.
  Iterable<TransferJob> get jobs => _records.values.map((r) => r.job);

  /// Job [id], or null when none is kept.
  TransferJob? job(TransferId id) => _records[id]?.job;

  /// Job [id]'s whole record, or null when none is kept.
  JournalRecord? record(TransferId id) => _records[id];

  /// What the storage is.
  JournalStoreKind get kind => _store.kind;

  /// The journal's state now, for a debug panel.
  JournalDebugSnapshot debugSnapshot() => JournalDebugSnapshot(
    store: _store.kind.name,
    bytes: _bytes,
    recordsSinceCompaction: _recordsSinceCompaction,
    lastStateWriteAt: _lastStateWriteAt,
    lastProgressFlushAt: _lastProgressFlushAt,
  );

  /// Completes when every write made so far has finished. A progress
  /// batch still waiting for its window is not one of them.
  @internal
  Future<void> get idle => _tail;

  // --- Writes ----------------------------------------------------------------

  /// Keeps [job] and writes it at once: a new job or a change of state.
  void writeState(TransferJob job) {
    if (_closed) return;
    final record = _put(job);
    _progressPending.remove(job.id);
    _enqueue(
      _codec.encode([JournalEntry$Put(record)]),
      records: 1,
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
    if (_closed) return;
    if (!_records.containsKey(job.id)) return writeState(job);
    _put(job);
    _progressPending.add(job.id);
    _progressTimer ??= Timer(progressInterval, _flushProgress);
  }

  /// Forgets job [id] and writes that at once.
  void remove(TransferId id) {
    if (_closed || _records.remove(id) == null) return;
    _progressPending.remove(id);
    _enqueue(
      _codec.encode([JournalEntry$Remove(id)]),
      records: 1,
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
  Future<void> compact() {
    _enqueueOp(_compact);
    return _tail;
  }

  /// Writes the progress still batched, waits for every write, and releases
  /// the store. Writes after this are ignored.
  Future<void> close() async {
    if (_closed) return _tail;
    _flushProgress();
    _closed = true;
    await _tail;
    await _store.close();
  }

  /// Stops at this point as a killed process would: progress still batched
  /// is lost, writes not yet begun are never made, and a write under way
  /// finishes or not as the store makes it.
  @internal
  void abandon() {
    if (_closed) return;
    _closed = true;
    _abandoned = true;
    _progressTimer?.cancel();
    _progressTimer = null;
    _progressPending.clear();
    unawaited(_tail.then((_) => _store.close()));
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
    if (_closed || _progressPending.isEmpty) return;
    final entries = [
      for (final id in _progressPending)
        if (_records[id] case final record?) JournalEntry$Put(record),
    ];
    _progressPending.clear();
    _enqueue(
      _codec.encode(entries),
      records: entries.length,
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

  /// Appends [bytes], holding [records] entries, after the writes before
  /// them; [onWritten] runs with the bytes written once they are durable.
  ///
  /// Callers encode before they enqueue, so a record that cannot be encoded
  /// throws where it was made rather than inside the chain of writes.
  void _enqueue(
    Uint8List bytes, {
    required int records,
    required void Function(int bytes) onWritten,
    TransferId? jobId,
  }) => _enqueueOp(() async {
    if (_rewrite) {
      // Memory already holds these entries; the rewrite writes them.
      if (await _compact()) onWritten(0);
      return;
    }
    try {
      await _store.append(bytes);
    } on Object catch (error, stackTrace) {
      _failed(error, stackTrace, jobId);
      return;
    }
    _bytes += bytes.length;
    _recordsSinceCompaction += records;
    onWritten(bytes.length);
    if (_recordsSinceCompaction >= compactAfter) await _compact();
  });

  void _enqueueOp(Future<void> Function() op) {
    _tail = _tail.then((_) => _abandoned ? null : op());
  }

  /// Writes every record kept as the new snapshot and starts an empty log;
  /// answers whether it was written.
  Future<bool> _compact() async {
    final began = _now();
    final before = _bytes;
    final generation = _generation + 1;
    final snapshot = _codec.encode([
      JournalEntry$Header(generation),
      for (final record in _records.values) JournalEntry$Put(record),
    ]);
    final log = _codec.encode([JournalEntry$Header(generation)]);
    // The snapshot holds the batched progress too.
    _progressPending.clear();
    try {
      await _store.replace(snapshot: snapshot, log: log);
    } on Object catch (error, stackTrace) {
      _failed(error, stackTrace, null);
      return false;
    }
    _generation = generation;
    _bytes = snapshot.length + log.length;
    _recordsSinceCompaction = 0;
    _rewrite = false;
    MpxDiagnostics.current.emit(
      MpxEventLevel.debug,
      JournalOp.compacted,
      fields: () => {
        'bytesBefore': before,
        'bytesAfter': _bytes,
        'ms': _now().difference(began).inMilliseconds,
      },
    );
    return true;
  }

  void _failed(Object error, StackTrace stackTrace, TransferId? jobId) {
    // A failed append may have left part of a frame, and everything after
    // a broken frame reads as a torn tail: the next write rewrites it all.
    _rewrite = true;
    _emitWriteFailed(_store, error, stackTrace, jobId: jobId);
  }

  static void _emitWriteFailed(
    JournalStore store,
    Object error,
    StackTrace stackTrace, {
    TransferId? jobId,
  }) => MpxDiagnostics.current.emit(
    MpxEventLevel.error,
    JournalOp.writeFailed,
    jobId: jobId,
    // The error itself stays out: a file system error names its path.
    fields: () => {'code': store.errorCode(error)},
    stackTrace: stackTrace,
  );

  static String _stateName(TransferState state) => switch (state) {
    TransferState$Queued() => 'queued',
    TransferState$Running() => 'running',
    TransferState$Paused() => 'paused',
    TransferState$Failed() => 'failed',
    TransferState$Completed() => 'completed',
  };
}
