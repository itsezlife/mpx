import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_transfer/src/diagnostics/journal_op.dart';
import 'package:mpx_transfer/src/journal/journal_frames.dart';
import 'package:mpx_transfer/src/journal/journal_store.dart';

/// What [RecordLog.read] read back from a store.
final class RecordLogRead<E> {
  RecordLogRead._({
    required this.store,
    required this.entries,
    required this.generation,
    required this.bytes,
    required this.skipped,
    required this.table,
    required this.now,
  });

  /// The store the log writes to: the one read, or memory when that one
  /// could not be read.
  final JournalStore store;

  /// The entries read, snapshot first, then the log written after it.
  final List<E> entries;

  /// The compaction count the snapshot carries.
  final int generation;

  /// The bytes read.
  final int bytes;

  /// Whole frames that could not be read back (a newer version's entry,
  /// one cut short inside its JSON): skipped and counted.
  final int skipped;

  /// The table named in the log's events; null for the transfer journal.
  final String? table;

  /// The clock.
  final DateTime Function() now;
}

/// The durable log under each of the package's stores (the transfer
/// journal, the publish journal, the reuse table): entries framed into a
/// [JournalStore]'s snapshot and log, read back at a start, appended one
/// write at a time and folded into a fresh snapshot.
///
/// - **Read.** [read] replays the snapshot, then the log written after
///   it. A store that cannot be read is reported (`writeFailed`) and
///   replaced by memory for the run, so its owner starts empty rather than
///   not at all; what the store holds is left for the next start. A torn
///   tail is dropped and reported (`tornTailDropped`); a whole frame its
///   [Codec] cannot read is skipped and counted ([RecordLogRead.skipped]).
/// - **Generation.** Each compaction writes a header frame,
///   `{"header": generation}`, first in the snapshot and in the log. A kill
///   between the two steps of a compaction leaves the new snapshot beside
///   the old log; the log's generation is then not the snapshot's, and the
///   log is dropped, since the snapshot already holds it. A blob with no
///   header (written before headers) is generation 0.
/// - **Writes.** One at a time, in the order made; a write after [close]
///   or [abandon] is ignored. A write the store refuses leaves the owner's
///   memory as it is and makes the next write rewrite the whole store from
///   the owner's live entries, so nothing is lost behind a broken frame.
///
/// Internal to the package.
final class RecordLog<E> {
  /// A log continuing [read], encoding through [codec]. [live] gives the
  /// owner's entries at a compaction; [beforeCompaction] runs just before
  /// they are taken.
  RecordLog(
    RecordLogRead<E> read, {
    required Codec<E, Object?> codec,
    required Iterable<E> Function() live,
    required this.compactAfter,
    void Function()? beforeCompaction,
  }) : _store = read.store,
       _codec = codec,
       _live = live,
       _beforeCompaction = beforeCompaction,
       _generation = read.generation,
       _bytes = read.bytes,
       _table = read.table,
       _now = read.now;

  /// Reads [store] back through [codec]; [table] names the store in the
  /// events (null for the transfer journal).
  static Future<RecordLogRead<E>> read<E>(
    JournalStore store, {
    required Codec<E, Object?> codec,
    String? table,
    DateTime Function() now = DateTime.now,
  }) async {
    var source = store;
    Uint8List snapshotBytes;
    Uint8List logBytes;
    try {
      snapshotBytes = await source.read(JournalBlob.snapshot);
      logBytes = await source.read(JournalBlob.log);
    } on Object catch (error, stackTrace) {
      _emitWriteFailed(source, error, stackTrace, table: table);
      source = MemoryJournalStore();
      snapshotBytes = logBytes = Uint8List(0);
    }
    final snapshot = JournalFrames.decode(snapshotBytes);
    final log = JournalFrames.decode(logBytes);
    final generation = _generationOf(snapshot.payloads);
    // A log of another generation predates the snapshot: a kill fell
    // between the two steps of a compaction.
    final logPayloads = _generationOf(log.payloads) == generation
        ? log.payloads
        : const <Object?>[];
    final entries = <E>[];
    var skipped = 0;
    for (final payload in [...snapshot.payloads, ...logPayloads]) {
      if (payload case {_Key.header: int()}) continue;
      try {
        entries.add(codec.decode(payload));
      } on Object {
        // A whole frame that does not read back is an entry of a version
        // this build does not know: counted, reported by the owner.
        skipped++;
      }
    }
    final bytes = snapshotBytes.length + logBytes.length;
    MpxDiagnostics.current.emit(
      MpxEventLevel.info,
      JournalOp.opened,
      fields: () => {
        'records': entries.length + skipped,
        'bytes': bytes,
        'store': source.kind.name,
        'table': ?table,
      },
    );
    final torn = snapshot.tornBytes + log.tornBytes;
    if (torn > 0) {
      MpxDiagnostics.current.emit(
        MpxEventLevel.warning,
        JournalOp.tornTailDropped,
        fields: () => {'bytesDropped': torn, 'table': ?table},
      );
    }
    return RecordLogRead._(
      store: source,
      entries: entries,
      generation: generation,
      bytes: bytes,
      skipped: skipped,
      table: table,
      now: now,
    );
  }

  /// How many entries the log takes before it is folded during a run.
  final int compactAfter;

  final JournalStore _store;
  final Codec<E, Object?> _codec;
  final Iterable<E> Function() _live;
  final void Function()? _beforeCompaction;
  final String? _table;
  final DateTime Function() _now;

  int _generation;
  int _bytes;
  int _sinceCompaction = 0;
  bool _rewrite = false;
  bool _closed = false;
  bool _abandoned = false;
  Future<void> _tail = Future.value();

  /// What the storage is.
  JournalStoreKind get kind => _store.kind;

  /// The bytes the store holds.
  int get bytes => _bytes;

  /// The entries appended since the last compaction.
  int get sinceCompaction => _sinceCompaction;

  /// Whether writes are ignored: after [close] or [abandon].
  bool get isClosed => _closed;

  /// Completes when every write made so far has finished.
  Future<void> get idle => _tail;

  /// Appends [entries] after the writes before them; completes once they
  /// are durable, or failed (reported). [onWritten] runs with the bytes
  /// written once they are; [trace] names the write's trace section.
  ///
  /// Encoded here, so an entry that cannot be encoded throws where it was
  /// made rather than inside the chain of writes.
  Future<void> append(
    List<E> entries, {
    void Function(int bytes)? onWritten,
    DiagnosticOp trace = JournalOp.stateWritten,
    String? jobId,
  }) {
    if (_closed) return _tail;
    final bytes = JournalFrames.encode(entries.map(_codec.encode));
    return _enqueue(() async {
      if (_rewrite) {
        // Memory already holds these entries; the rewrite writes them.
        if (await _compact()) onWritten?.call(0);
        return;
      }
      try {
        await MpxTrace.async(trace, () => _store.append(bytes));
      } on Object catch (error, stackTrace) {
        _failed(error, stackTrace, jobId: jobId);
        return;
      }
      _bytes += bytes.length;
      _sinceCompaction += entries.length;
      onWritten?.call(bytes.length);
      if (_sinceCompaction >= compactAfter) await _compact();
    });
  }

  /// Folds the log into a fresh snapshot after the writes made so far.
  Future<void> compact() => _enqueue(_compact);

  /// Waits for every write and releases the store. Writes after this are
  /// ignored.
  Future<void> close() async {
    if (_closed) return _tail;
    _closed = true;
    await _tail;
    await _store.close();
  }

  /// Stops as a killed process would: writes not yet begun are never made,
  /// and a write under way finishes or not as the store makes it.
  void abandon() {
    if (_closed) return;
    _closed = true;
    _abandoned = true;
    unawaited(_tail.then((_) => _store.close()));
  }

  Future<void> _enqueue(Future<void> Function() op) =>
      _tail = _tail.then((_) => _abandoned ? null : op());

  /// Writes the owner's live entries as the new snapshot, after a header
  /// of the next generation, and starts a log of that generation; answers
  /// whether it was written.
  Future<bool> _compact() async {
    final began = _now();
    final before = _bytes;
    final generation = _generation + 1;
    final header = {_Key.header: generation};
    _beforeCompaction?.call();
    final snapshot = JournalFrames.encode([
      header,
      ..._live().map(_codec.encode),
    ]);
    final log = JournalFrames.encode([header]);
    try {
      await MpxTrace.async(
        JournalOp.compacted,
        () => _store.replace(snapshot: snapshot, log: log),
      );
    } on Object catch (error, stackTrace) {
      _failed(error, stackTrace);
      return false;
    }
    _generation = generation;
    _bytes = snapshot.length + log.length;
    _sinceCompaction = 0;
    _rewrite = false;
    MpxDiagnostics.current.emit(
      MpxEventLevel.debug,
      JournalOp.compacted,
      fields: () => {
        'bytesBefore': before,
        'bytesAfter': _bytes,
        'ms': _now().difference(began).inMilliseconds,
        'table': ?_table,
      },
    );
    return true;
  }

  void _failed(Object error, StackTrace stackTrace, {String? jobId}) {
    // A failed append may have left part of a frame, and everything after
    // a broken frame reads as a torn tail: the next write rewrites it all.
    _rewrite = true;
    _emitWriteFailed(_store, error, stackTrace, jobId: jobId, table: _table);
  }

  static int _generationOf(List<Object?> payloads) =>
      switch (payloads.firstOrNull) {
        {_Key.header: final int generation} => generation,
        _ => 0,
      };

  static void _emitWriteFailed(
    JournalStore store,
    Object error,
    StackTrace stackTrace, {
    String? jobId,
    String? table,
  }) => MpxDiagnostics.current.emit(
    MpxEventLevel.error,
    JournalOp.writeFailed,
    jobId: jobId,
    // The error itself stays out: a file system error names its path.
    fields: () => {'code': store.errorCode(error), 'table': ?table},
    stackTrace: stackTrace,
  );
}

/// The frame the log itself writes.
abstract final class _Key {
  static const String header = 'header';
}
