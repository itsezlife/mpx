import 'package:mpx_core/mpx_core.dart';

/// The diagnostics operations of the journal, category `journal`: the
/// engine reading its jobs back at a start, writing their changes, and
/// folding the log into a snapshot.
///
/// On the web also an upload job's sources copied into OPFS, or not.
///
/// No field carries user content: counts, byte sizes, times and the store
/// kind; the job id is the event's correlation id.
enum JournalOp implements DiagnosticOp {
  /// The journal's storage was read at a start (info; `records` read,
  /// `bytes` read, `store`: `file`, `opfs` or `memory`).
  opened,

  /// The jobs were rebuilt from what was read (info; `jobs`, `uploads`,
  /// `downloads`, `ms` since the read began; `skipped` when records could
  /// not be read back, such as one from a newer version).
  replayed,

  /// The log ended in a record cut short, as by a kill in the middle of a
  /// write; it was dropped (warning; `bytesDropped`).
  tornTailDropped,

  /// A job's state change was written and flushed (trace; `state`: the
  /// state's name, or `removed`; job).
  stateWritten,

  /// A batch of progress was written and flushed (trace; `jobs` in it,
  /// `bytes` written, `sinceLastMs` since the batch before it).
  progressFlushed,

  /// The log was folded into a snapshot (debug; `bytesBefore`,
  /// `bytesAfter`, `ms`).
  compacted,

  /// Completed jobs past their retention were forgotten (debug; `jobs`,
  /// `olderThanH`, the retention in hours).
  pruned,

  /// The storage refused a read or a write (error; `code`, the storage's
  /// error code; job, when the write was one job's). The jobs stay in
  /// memory, and the next write rewrites the whole journal. On the web
  /// also a copy of an upload source that the storage refused, or an OPFS
  /// that refused to open. The reuse table's storage reports here too, with
  /// `table: reuse`.
  writeFailed,

  /// On the web, an upload job's sources were copied into OPFS at its
  /// creation, so the job survives a reload (debug; `bytes` copied, `ms`;
  /// job).
  sourceCopied,

  /// On the web, an upload job's sources are larger together than the copy
  /// limit, so they were not copied: the job runs from the page's file and
  /// does not survive a reload (warning; `bytes`, the sources' sum,
  /// `limit`; job).
  sourceOverLimit,

  /// On the web, an upload job came back from a reload without a copy of
  /// its sources (over the limit, no OPFS, or a copy the reload cut short):
  /// it is failed with `sourceLost` (error; job).
  sourceLost;

  @override
  String get category => 'journal';
}
