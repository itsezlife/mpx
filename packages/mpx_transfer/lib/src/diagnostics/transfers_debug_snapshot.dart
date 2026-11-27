import 'package:meta/meta.dart';
import 'package:mpx_transfer/src/job/transfer_job.dart';

/// The transfer engine's state at one moment, for a debug panel: read on
/// demand through `Transfers.debugSnapshot`, never streamed.
///
/// Sections arrive with the parts of the engine they describe; this one
/// holds the jobs, connectivity and the journal.
@immutable
final class TransfersDebugSnapshot {
  /// A snapshot of [jobs], [online] and [journal].
  TransfersDebugSnapshot({
    required List<TransferJob> jobs,
    required this.online,
    required this.journal,
  }) : jobs = List.unmodifiable(jobs);

  /// Every job not yet completed, oldest first, with its id, tag,
  /// direction, state (and pause reason), durability, bytes and times.
  final List<TransferJob> jobs;

  /// Connectivity as the composition root last reported it.
  final bool online;

  /// Where the jobs are kept, and how far behind memory it is.
  final JournalDebugSnapshot journal;

  @override
  String toString() =>
      'TransfersDebugSnapshot(${jobs.length} jobs, online: $online, '
      '$journal)';
}

/// The journal section of a [TransfersDebugSnapshot].
@immutable
final class JournalDebugSnapshot {
  /// A snapshot of the journal.
  const JournalDebugSnapshot({
    required this.store,
    required this.bytes,
    required this.recordsSinceCompaction,
    this.lastStateWriteAt,
    this.lastProgressFlushAt,
  });

  /// The storage's kind: `file`, `opfs` or `memory`.
  final String store;

  /// The journal's size in storage: the snapshot and the log.
  final int bytes;

  /// Records appended to the log since it was last folded into the
  /// snapshot.
  final int recordsSinceCompaction;

  /// When a state change was last written and flushed; null before any in
  /// this run.
  final DateTime? lastStateWriteAt;

  /// When a progress batch was last written and flushed; null before any in
  /// this run.
  final DateTime? lastProgressFlushAt;

  @override
  String toString() =>
      'JournalDebugSnapshot($store, $bytes bytes, '
      '$recordsSinceCompaction since compaction)';
}
