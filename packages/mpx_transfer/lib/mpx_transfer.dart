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
/// `SchedulerOp`, `TransportOp`, `EnvelopeOp`, `ReuseOp`, `PublishOp` and
/// `PublishPreparationOp`; `debugSnapshot` gives a
/// debug panel the engine's state.
///
/// An upload reads an `UploadSource` and reaches its remote end through an
/// `UploadTransport`, which declares what it supports
/// (`UploadCapabilities`); the engine splits, budgets, retries and
/// journals the parts, and a completed upload holds a `RemoteRef`. The
/// reuse table (`Transfers.reuse`) keeps those references by source, so
/// the same media sent again is neither prepared nor uploaded again.
///
/// A publish job (`Transfers.publish`) takes an ordered list of items,
/// prepares each through the core's `MediaPreparation`, uploads it and
/// then calls the host's `Publisher`, registered by id, once with every
/// item's references and one idempotency key. Its items and state are
/// journaled too, and `PublishJob.watch` streams its snapshots;
/// `Transfers.upload` is the same job with one item and no publisher.
/// `TusUploadTransport` speaks the tus resumable upload protocol.
///
/// Single-threaded on the UI isolate.
library;

export 'src/diagnostics/envelope_op.dart';
export 'src/diagnostics/journal_op.dart';
export 'src/diagnostics/publish_op.dart';
export 'src/diagnostics/reuse_op.dart';
export 'src/diagnostics/scheduler_op.dart';
export 'src/diagnostics/transfers_debug_snapshot.dart';
export 'src/diagnostics/transport_op.dart';
export 'src/download/downloaded_content.dart';
export 'src/download/transfer_downloads.dart';
export 'src/envelope/transfer_envelope.dart';
export 'src/envelope/transfer_envelope_config.dart';
export 'src/job/transfer_id.dart';
export 'src/job/transfer_job.dart';
export 'src/job/transfer_state.dart';
export 'src/publish/publish_job.dart';
export 'src/publish/publish_request.dart';
export 'src/publish/publish_state.dart';
export 'src/publish/publisher.dart';
export 'src/reuse/reuse_table.dart';
export 'src/transfers.dart';
export 'src/upload/multipart_upload_transport.dart';
export 'src/upload/numbered_parts_transport.dart';
export 'src/upload/remote_ref.dart';
export 'src/upload/tus_upload_transport.dart';
export 'src/upload/upload_lane.dart';
export 'src/upload/upload_source.dart';
export 'src/upload/upload_transport.dart' hide UploadPartSend;
