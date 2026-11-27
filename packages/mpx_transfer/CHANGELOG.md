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
  is reported and the engine runs in memory for that run. On the web the
  journal is in memory for now.
- `JournalOp` diagnostics operations, and the journal section of
  `debugSnapshot()`: store, bytes, records since compaction, last state
  write and last progress flush.
- `TransferJob`, `TransferId` (derived from the cache key for a download),
  `TransferState` with `PauseReason` and `TransferFailureKind`,
  `TransferDurability`, `TransferDirection`, `TransferFilter`.
- `TransferEnvelope`, the seam of the OS envelope, with its events.
- `SchedulerOp` and `EnvelopeOp` diagnostics operations.
- `testing.dart`: `FakeTransferEnvelope`, `ScriptedTransferRunner`,
  `FakeTransferResult`, `MemoryJournalStore`, `JournalStoreContract`, and
  `TransfersHarness` (opened with `TransfersHarness.open`; `restart`,
  `kill`, `settle`, `replayed`).
