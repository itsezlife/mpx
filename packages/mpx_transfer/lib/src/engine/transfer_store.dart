import 'package:mpx_transfer/src/job/transfer_id.dart';
import 'package:mpx_transfer/src/job/transfer_job.dart';

/// Where the engine keeps its transfer jobs, the queries' source of truth.
///
/// In memory for now; the journal, which survives the process, takes its
/// place. Internal to the package.
abstract interface class TransferStore {
  /// Every job kept, in the order they were first written.
  Iterable<TransferJob> get jobs;

  /// Job [id], or null when none is kept.
  TransferJob? job(TransferId id);

  /// Keeps [job], replacing the job with its id.
  void write(TransferJob job);

  /// Forgets job [id].
  void delete(TransferId id);
}

/// A [TransferStore] in memory: it lives as long as the object, so a new
/// engine over the same store sees what the last one left, as after a
/// restart.
final class MemoryTransferStore implements TransferStore {
  final Map<TransferId, TransferJob> _jobs = {};

  @override
  Iterable<TransferJob> get jobs => _jobs.values;

  @override
  TransferJob? job(TransferId id) => _jobs[id];

  @override
  void write(TransferJob job) => _jobs[job.id] = job;

  @override
  void delete(TransferId id) => _jobs.remove(id);
}
