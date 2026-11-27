# Changelog

## Unreleased

- Uploads through `Transfers.tracked`: `watch(key)` of a publish job
  item's local key reads its uploads (file and thumbnail together):
  `waiting` while queued, `sending(sent, total)` while running and held
  while paused by the system or for the network, `awaitingUser` paused by
  the user, `failed`, then `sent` until its job published and aliased its
  server keys, and `none` after, the local picture kept. A one-item
  `upload` reads `none` once uploaded. `cancel(key)` removes the item from
  its job (`itemRemoved`, by: cell; the last one leaves the job
  `awaitingOwner`); `download(key)` resumes an upload the user paused and
  retries a failed item instead of starting a download. `binding.mapped`
  carries the file upload's id, the item id, its state and the value.
  `tracked` is there on a facade with downloads or with uploads to
  publish; without downloads, `download` of a key with no upload and
  `leaseFile` do nothing.
- `UploadsHarness.open(downloads:)`: tracked downloads beside the uploads.

- Ordering groups: jobs sharing an `orderingGroup` publish in creation
  order; a failed job lets later ones go on and, retried, publishes after
  them. The order is journaled.
- Hold and commit: a `hold: true` job publishes only on
  `PublishJob.commit(payload:)`; before that `addItem`, `reorder`,
  `setPayload`, `removeItem` and `cancel` apply. `PublishJobSnapshot.held`.
- Item cancel: `removeItem` takes the last item too, leaving the job
  `awaitingOwner` until its owner commits or cancels it; a
  `Transfers.cancel` of an item's upload now removes the item (it used to
  fail it). `PublishJob.cancel()` removes the job and its uploads.
  `watchItem` ends with a `removed` snapshot.
- Diagnostics: `PublishOp.groupWait`, `committed`, `awaitingOwner` and
  `cancelled` (`by: owner` or `envelope`); `itemRemoved` reports
  `by: host` or `cell`.

- OS envelope: `TransferEnvelopeConfig` (title, text, cancel-all label,
  progress text, icon, `startRule`, `longJobBytes` 10 MiB, `submitAt`
  `afterDelay(10 s)` or `onResignActive`) through
  `Transfers.open(envelopeConfig:)`; without one `system` jobs run in
  process, reported once. The engine starts the envelope by the start rule
  (`long`, `always`, `never`), stops it when its jobs drain, and journals
  its handle with each job, taking over a live one after a restart. A
  refused start runs its jobs in process. A system end pauses every job
  inside `systemInterrupted`; a cancel of all from the system's UI cancels
  them and their publish jobs. `Transfers.notificationTaps`,
  `debugSimulateSystemInterruption()` and `debugSnapshot().envelope`.
  Breaking for `TransferEnvelope` implementers: `startRule`, `live`,
  `adopt`, and `start` takes the config and answers
  `TransferEnvelopeStart`; `systemEnded` carries a cause, and a `changed`
  event reports the kind and the submission time.

- Publish outcomes: `PublishOutcome.reuploadItems(ids)` (the items' reuse
  entries dropped, the items uploaded again and published again with the
  same key; honoured once, a second one fails the job) and
  `PublishOutcome.rejected(reason:, retryable:)` (failed at the publish
  stage). After `published`, each server key is aliased to its item's
  local key in the bytes cache, both through `cacheKeyOf`, once the
  completion is journaled; a kill in between applies the aliases at the
  next start. `Transfers.open(cache:)` names that cache (`downloads.store`
  by default); `PublishJobSnapshot.aliasesApplied` tells when it is done.
- `PublishJob.retry()`, `retryItem(id)` and `removeItem(id)`: a retry
  repeats only what failed, keeping finished preparations and journaled
  uploads (a failed upload goes on from its parts); the per-item policy
  holds the publish until a failed item is retried or removed. The last
  item of a job is not removed yet.
- Diagnostics: `PublishOp.aliasApplied`, `reuploadRefused`, `retry` and
  `itemRemoved`; `outcome` reports `rejected` as a warning and
  `reuploadItems` with its item count. An upload a publish job cancels is
  reported `cancelled` with `by: owner`.
- `UploadsHarness.open(cache:)`.
- Publish progress: `PublishJobSnapshot.progress` and
  `PublishItemSnapshot.progress`, 0..1 and byte-weighted, on `watch()` and
  `watchItem(id)`. Before its preparation ends an item weighs its source's
  size (`PreparationInput.byteSize`, else the file's), then its upload's
  bytes; a video's preparation takes 30 % of its item, a photo's or a
  file's 2 %, and the publisher's call the last 5 % of the job
  (`PublishProgressWeights`, set with `Transfers.open(progressWeights:)`).
  A remote item or a reuse hit counts as done at once. The value never goes
  back: a re-estimate stretches the rest of the ring over the new remaining
  work, and the job record keeps the value a restart starts from (an
  optional `progress` field in the version 1 publish record). Progress
  reports no diagnostics events.
- `Transfers.watchJobs(PublishJobFilter)`: lists of publish job snapshots
  by tag, tag prefix, publisher and state, oldest first, from the journal
  after a restart.

- Publish jobs: `Transfers.publish(PublishRequest)` (tag, ordered
  `PublishItem`s, an opaque payload, a publisher id, a transport, durability
  `system` by default, failure policy, ordering group, hold, an optional
  idempotency key), `registerPublisher(id, Publisher)`, `publishJob(id)` and
  `upload(item)`, a one-item job with no publisher. Each item is remote,
  reused from the reuse table, prepared through `Transfers.open(preparation:)`
  or already prepared; it uploads as a transfer job of its own with the
  job's tag (and its thumbnail separately when the transport says so). The
  publisher is called once every item is uploaded, with one idempotency key
  on every attempt; `PublishOutcome.published` completes the job. Jobs are
  kept in `publish.*` beside the journal and survive any kill.
  `PublishJob.watch()` / `watchItem(id)` give `PublishJobState` and
  `PublishItemState` snapshots. A facade without preparation refuses an item
  that needs it with `PreparationUnavailable`.
- `Transfers.open` runs uploads: `transports` and `client` (the bytes
  cache's HTTP client) are new parameters, and on the web the source copies
  are read. `retry(id, source:)` gives a failed upload a new source file.
- Diagnostics: `PublishOp` (`jobCreated`, `itemStage`, `remoteItem`,
  `awaitingPublisher`, `publisherRegistered`, `attempt`, `outcome`),
  `PublishPreparationOp.refusedNoSeam`, `TransportOp.thumbnailUpload`;
  `debugSnapshot().publish`.
- `testing.dart`: `FakePublisher`; `UploadsHarness` runs publish jobs
  (`preparation`, `reuse`). `FakeUploadTransport` numbers each finish
  before it waits, so finishes under way together answer distinct
  references.
- A `TransferJob.key` of an upload is the item a publish job sends.

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
- `TusUploadTransport`: the tus resumable upload protocol 1.0.0 (core,
  creation and expiration). A `POST` creates the upload with its length
  and metadata; each part is a `PATCH` at the server's offset, one at a
  time (1 MiB parts, 4 MiB above 10 MiB); the upload's URL is the resume
  token. A restart asks the server's offset (`HEAD`) and sends only what it
  lacks; an upload the server forgot (404, 410) or whose `Upload-Expires`
  passed starts again from zero. A part broken off midway goes on from the
  server's offset. `thumbnail: none`; a stored reference is good while the
  server still holds the whole upload (`UploadReuse.validity`).
- `UploadOffsetSession`: a session that tells the remote end's offset, by
  which the engine resumes instead of the journal's parts.
  `UploadPartBody.send` takes `from`, to skip the bytes the remote end
  holds.
- `UploadTransportContract` checks the `thumbnail` capability (a separate
  thumbnail uploads beside its item) and the `reuse` one (a reference just
  answered is good).
- Resume rules: a run of an upload that ran before continues with its
  token only when the source file is unchanged (its size and modification
  time, kept in the journal) and the transport's window is open
  (`UploadResume.window` by size since the upload last moved, or the
  remote end's expiry the session gave, journaled with the token). A
  changed file, a closed window, a transport without resume, or a remote
  end that no longer has the upload start it from zero under the same job,
  its acknowledged parts dropped; none of them fails it. A file that is
  gone fails the job `sourceLost`, retryable once the file is back.
  `TransportOp.resumeDecision` reports the outcome. `FakeUploadTransport`
  gains `resumeExpiresAt`.
- `TransportOp` diagnostics operations; `SchedulerOp` gains `slotAcquired`
  and `slotReleased`, and `jobQueued` and `jobStarted` carry an upload's
  `lane`. `debugSnapshot()` gains `uploads` (lanes, parts in flight, part
  retries, restarts from zero) and `connections`.
- The reuse table (`Transfers.reuse`): the references an upload answered,
  kept by source (`ReuseKey`: the host's fingerprint, or path, size and
  modification time, plus the preparation) and transport, beside the
  journal on the VM and in OPFS on the web, so the same media sent again
  is neither prepared nor uploaded again. The transport's `reuse`
  capability judges a stored reference (a lifetime or a validity call);
  `invalidate` drops an entry; `Transfers.open(reuse:)` takes a
  `ReusePolicy` to turn it off or set its expiry (7 days by default).
  `ReuseOp` diagnostics and the `reuse` section of `debugSnapshot()`;
  `ReuseTableContract` in `testing.dart`.
- `TransferEnvelope`, the seam of the OS envelope, with its events.
- `SchedulerOp` and `EnvelopeOp` diagnostics operations.
- `testing.dart`: `FakeTransferEnvelope`, `ScriptedTransferRunner`,
  `FakeTransferResult`, `MemoryJournalStore`, `JournalStoreContract`,
  `FakeUploadSourceCopies`, `UploadSourceCopiesContract`,
  `FakeUnloadWarning`, `FakeUploadSourceFiles` (over the
  `UploadSourceFiles` seam), `FakeUploadTransport` with the
  `UploadTransportContract`, `UploadsHarness` (uploads through the real
  engine), and
  `TransfersHarness` (opened with `TransfersHarness.open`; `restart`,
  `kill`, `settle`, `replayed`; `downloads` to run download jobs for real).
