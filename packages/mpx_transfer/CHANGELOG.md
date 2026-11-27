# Changelog

## Unreleased

- `Transfers.systemActive`: a `ValueListenable<bool>`, true while a `system`
  job is queued or running, for a host's quit confirmation on desktop
  platforms, which have no OS envelope. The `scheduler` events of a job
  carry its `durability`.
- The package: a single plugin for Android, iOS, macOS, Windows, Linux and
  the web, its native parts empty for now.
- `Transfers`: the facade, opened with `Transfers.open`, with
  `watch(filter)`, `pause`, `resume`, `cancel`, `retry`, `setPriority`,
  `connectivityChanged(online:)`, `debugSnapshot()` and `dispose()`.
  Completed jobs stay queryable for 24 hours, `retention` to change it.
- The journal: every job is kept in an append-only log in `mpx_transfer`
  below the bytes cache's directory (`directory`), folded into a snapshot
  at each start and every 1000 records. A state change is written and
  flushed at once; progress at most every 250 ms (`progressInterval`). A
  start after a kill reads every job back in its last flushed state; a
  record cut short by the kill is dropped. A journal that cannot be read
  is reported and the engine runs in memory for that run.
- The journal on the web: in `mpx_transfer` at the OPFS root, beside the
  bytes cache's store, written on the main thread in the same batches;
  in memory where the page has no OPFS. An upload's sources are copied
  into OPFS at its creation when they fit `sourceCopyLimit` together
  (500 MiB, `Transfers.defaultSourceCopyLimit`) and deleted when the job
  completes, is cancelled or is pruned; a job whose sources were not kept
  comes back from a reload failed with `sourceLost`. Leaving the page
  asks first while a job is queued or running. `JournalOp` gains
  `sourceCopied`, `sourceOverLimit` and `sourceLost`.
- `JournalOp` diagnostics operations, and the journal section of
  `debugSnapshot()`: store, bytes, records since compaction, last state
  write and last progress flush.
- `TransferJob`, `TransferId` (derived from the cache key for a download),
  `TransferState` with `PauseReason` and `TransferFailureKind`,
  `TransferDurability`, `TransferDirection`, `TransferFilter`.
- Tracked downloads: `Transfers.download(key, origin:, resumeOnStart:,
  priority:)` and `Transfers.tracked`, the core's `TrackedTransfers` over
  the same jobs, for `AssetCacheScope(tracked:)` and savers. One job per
  key; the bytes stay in the bytes cache, fetched through the host's
  `ContentFetcher` and `MediaResolver` (`TransferDownloads`, passed to
  `Transfers.open(downloads:)`), so the cache's priority queue and
  connection cap serve them. After a restart a user download resumes from
  the cached bytes; an auto download waits paused `awaitingResume` until a
  surface watches its key. `cancel(key)` pauses for the user; `leaseFile`
  lends the cached file once whole. `DownloadedContent` is the result.
  Diagnostics: `scheduler.downloadRequested` and `binding.mapped`.
- The upload engine, inside the package until publish jobs bring its public
  entry. `UploadSource` (`finished`, and `growing`, which is refused with an
  `UnsupportedError` for now; `UploadSource.fromBytes` writes in-memory
  bytes to a temp file). The `UploadTransport` seam: `open(info,
  resumeToken:)` gives an `UploadSession` with `sendPart(index, offset,
  bytes, last:)` and `finish(finalSize, parts)`, which answers a
  `RemoteRef`; part bytes come as an `UploadPartBody` the engine streams
  from the file (the bytes cache's transfer worker on the VM, `fetch` with
  a `Blob` slice on the web). `UploadCapabilities`: part size by file size,
  a bytes-in-flight budget, `UploadResume`, known size required, head
  last, `UploadThumbnail`, `UploadReuse`. The engine retries a part five
  tries in all (the bytes cache's `uploadPart` backoff), keeps each
  acknowledged part, with its receipt, in the job's next progress write,
  reopens with the resume token after a restart and sends only the parts
  not kept, and runs upload jobs in two lanes (`UploadLane`, split at
  10 MiB), one job each, under 8 shared connections (6 at most per
  direction).
- `MultipartUploadTransport`: an upload in one `multipart/form-data`
  request. The host's `request(info)` gives the URL, method, headers, form
  fields and the file's field, name and type per upload; `remoteRef` reads
  the answer into the `RemoteRef`. One part of the whole file, no resume (a
  restart sends it again from byte 0), `thumbnail: none`, and a stored
  reference good for 24 hours by default (`defaultReuse`).
  `UploadPartBody.send` takes a transport's `prefix` and `suffix` framing.
- `NumberedPartsTransport`: an upload in numbered parts sent in parallel,
  through the host's `start` (answers the upload id, also the resume
  token), `partRequest` (the URL, method and headers of part N, from 1)
  and `complete` (every part's number and receipt in order, to a
  `RemoteRef`); a part's receipt is its `ETag` by default (`receiptOf`).
  Parts of 128 KiB, 512 KiB above 10 MiB, growing past 4000 parts; 8 MiB
  in flight; resume within 1.5 h for files up to the 10 MiB lane split,
  24 h above; `thumbnail: separate`; a stored reference good for 24 hours.
  `NumberedPartsTransport.presignedMultipart` for S3, R2 and GCS: parts of
  8 MiB, at most 10 000, 32 MiB in flight.
- `UploadTransportContract` checks the `thumbnail` capability (a separate
  thumbnail uploads beside its item) and the `reuse` one (a reference just
  answered is good).
- `TransportOp` diagnostics operations; `SchedulerOp` gains `slotAcquired`
  and `slotReleased`, and `jobQueued` and `jobStarted` carry an upload's
  `lane`. `debugSnapshot()` gains `uploads` (lanes, parts in flight, part
  retries, restarts from zero) and `connections`.
- `TransferEnvelope`, the seam of the OS envelope, with its events.
- `SchedulerOp` and `EnvelopeOp` diagnostics operations.
- `testing.dart`: `FakeTransferEnvelope`, `ScriptedTransferRunner`,
  `FakeTransferResult`, `MemoryJournalStore`, `JournalStoreContract`,
  `FakeUploadSourceCopies`, `UploadSourceCopiesContract`,
  `FakeUnloadWarning`, `FakeUploadTransport` with the
  `UploadTransportContract`, `UploadsHarness` (uploads through the real
  engine), and
  `TransfersHarness` (opened with `TransfersHarness.open`; `restart`,
  `kill`, `settle`, `replayed`; `downloads` to run download jobs for real).
