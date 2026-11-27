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
/// `SchedulerOp`, `TransportOp`, `EnvelopeOp` and `ReuseOp`; `debugSnapshot` gives a
/// debug panel the engine's state.
///
/// An upload reads an `UploadSource` and reaches its remote end through an
/// `UploadTransport`, which declares what it supports
/// (`UploadCapabilities`); the engine splits, budgets, retries and
/// journals the parts, and a completed upload holds a `RemoteRef`. The
/// reuse table (`Transfers.reuse`) keeps those references by source, so
/// the same media sent again is neither prepared nor uploaded again.
///
/// Single-threaded on the UI isolate.
library;

export 'src/diagnostics/envelope_op.dart';
export 'src/diagnostics/journal_op.dart';
export 'src/diagnostics/reuse_op.dart';
export 'src/diagnostics/scheduler_op.dart';
export 'src/diagnostics/transfers_debug_snapshot.dart';
export 'src/diagnostics/transport_op.dart';
export 'src/download/downloaded_content.dart';
export 'src/download/transfer_downloads.dart';
export 'src/envelope/transfer_envelope.dart';
export 'src/job/transfer_id.dart';
export 'src/job/transfer_job.dart';
export 'src/job/transfer_state.dart';
export 'src/reuse/reuse_table.dart';
export 'src/transfers.dart';
export 'src/upload/multipart_upload_transport.dart';
export 'src/upload/numbered_parts_transport.dart';
export 'src/upload/remote_ref.dart';
export 'src/upload/upload_lane.dart';
export 'src/upload/upload_source.dart';
export 'src/upload/upload_transport.dart' hide UploadPartSend;
