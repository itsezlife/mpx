import 'package:meta/meta.dart';
import 'package:mpx_transfer/src/job/transfer_job.dart';

/// The transfer engine's state at one moment, for a debug panel: read on
/// demand through `Transfers.debugSnapshot`, never streamed.
///
/// Sections arrive with the parts of the engine they describe; this one
/// holds the jobs and connectivity.
@immutable
final class TransfersDebugSnapshot {
  /// A snapshot of [jobs] and [online].
  TransfersDebugSnapshot({
    required List<TransferJob> jobs,
    required this.online,
  }) : jobs = List.unmodifiable(jobs);

  /// Every job not yet completed, oldest first, with its id, tag,
  /// direction, state (and pause reason), durability, bytes and times.
  final List<TransferJob> jobs;

  /// Connectivity as the composition root last reported it.
  final bool online;

  @override
  String toString() =>
      'TransfersDebugSnapshot(${jobs.length} jobs, online: $online)';
}
