# Changelog

## Unreleased

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
- `TransferEnvelope`, the seam of the OS envelope, with its events.
- `SchedulerOp` and `EnvelopeOp` diagnostics operations.
- `testing.dart`: `FakeTransferEnvelope`, `ScriptedTransferRunner`,
  `FakeTransferResult`, `MemoryJournalStore`, `JournalStoreContract`,
  `FakeUploadSourceCopies`, `UploadSourceCopiesContract`,
  `FakeUnloadWarning`, and
  `TransfersHarness` (opened with `TransfersHarness.open`; `restart`,
  `kill`, `settle`, `replayed`; `downloads` to run download jobs for real).
