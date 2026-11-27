/// Transfer jobs for mpx: uploads and the downloads a user can see or must
/// keep, each with one sealed state, a `TransferId`, the host's opaque tag
/// and a durability, on one facade, `Transfers`.
///
/// A host makes one `Transfers` in its composition root. `watch(filter)`
/// streams snapshots of the jobs that match by direction, state, tag and
/// durability; `pause`, `resume`, `cancel`, `retry` and `setPriority` act
/// on one job; `connectivityChanged` feeds the device's connectivity in.
/// `download(key)` starts a tracked download, and `tracked` is the core's
/// `TrackedTransfers` seam over the same jobs, for the asset cache scope and
/// savers. A `system` job runs inside the platform's OS envelope
/// (`TransferEnvelope`) where there is one. Every job is journaled, so
/// after any kill `Transfers.open` reads the jobs back. Every path reports
/// through `MpxDiagnostics.current` with this package's `JournalOp`,
/// `SchedulerOp` and `EnvelopeOp`; `debugSnapshot` gives a debug panel the
/// engine's state.
///
/// Single-threaded on the UI isolate.
library;

export 'src/diagnostics/envelope_op.dart';
export 'src/diagnostics/journal_op.dart';
export 'src/diagnostics/scheduler_op.dart';
export 'src/diagnostics/transfers_debug_snapshot.dart';
export 'src/download/downloaded_content.dart';
export 'src/download/transfer_downloads.dart';
export 'src/envelope/transfer_envelope.dart';
export 'src/job/transfer_id.dart';
export 'src/job/transfer_job.dart';
export 'src/job/transfer_state.dart';
export 'src/transfers.dart';
