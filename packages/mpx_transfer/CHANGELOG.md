# Changelog

## 0.0.1 (unreleased)

First release: transfer jobs for mpx on one `Transfers` facade.

- Transfer jobs with one `TransferState`, a `TransferId`, the host's tag
  and a durability (`inProcess`, or `system` inside the platform's OS
  envelope); `watch(filter)`, `pause`, `resume`, `retry(id, source:)`,
  `cancel`, `setPriority` and `connectivityChanged`.
- A journal that brings every job back after any kill: a file beside the
  bytes cache on the VM, OPFS on the web (in memory where neither is). A
  state is flushed at once, progress at most every 250 ms; a remote end's
  finish answer is kept, so an upload never fails for a kill after it.
- Uploads through `UploadTransport`: `MultipartUploadTransport`,
  `NumberedPartsTransport` (with `presignedMultipart` for S3, R2 and GCS)
  and `TusUploadTransport`, in two lanes under a shared connection cap,
  resuming with what the remote end holds. Progress never goes back.
- Publish jobs (`publish`, `upload`, `registerPublisher`, `watchJobs`):
  items prepared through `MediaPreparation`, uploaded, then published once
  with one idempotency key; failure policies, retry of what failed,
  ordering groups, hold and commit, item removal, byte-weighted progress
  and `PublishFailureReason` for every failure. Server keys are aliased in
  the bytes cache after a publish, at the next start if a kill or a
  failed alias got in the way.
- A reuse table, so the same media sent again is neither prepared nor
  uploaded while its transport judges the stored reference good.
- Tracked downloads and uploads through `tracked`, the core's
  `TrackedTransfers`, for the asset cache scope.
- Page sources on the web (`SourceBytes.blob`, `SourceBytes.memory`),
  copied into OPFS so a job survives a reload; on the VM bytes in memory
  are written to a file, and `SourceBytes.file` is read where it is.
- OS envelopes: `AndroidTransferEnvelope` (user-initiated data transfer
  job, `dataSync` service before Android 14) and `IosTransferEnvelope`
  (background task, continued-processing task on iOS 26), configured with
  `TransferEnvelopeSetup`; see the README for the host's manifest and
  `Info.plist` entries.
- Diagnostics through `MpxDiagnostics` with no user content,
  `debugSnapshot()`, and `mpx.trace` timeline sections.
- `testing.dart`: fakes (envelope, transport, publisher, source copies,
  source files), contracts and harnesses over the real engine.
