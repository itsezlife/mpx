# Changelog

## Unreleased

- The package: a single plugin for Android, iOS, macOS, Windows, Linux and
  the web, its native parts empty for now.
- `Transfers`: the facade, with `watch(filter)`, `pause`, `resume`,
  `cancel`, `retry`, `setPriority`, `connectivityChanged(online:)` and
  `debugSnapshot()`, over an in-memory engine. Completed jobs stay
  queryable for 24 hours, `retention` to change it.
- `TransferJob`, `TransferId` (derived from the cache key for a download),
  `TransferState` with `PauseReason` and `TransferFailureKind`,
  `TransferDurability`, `TransferDirection`, `TransferFilter`.
- `TransferEnvelope`, the seam of the OS envelope, with its events.
- `SchedulerOp` and `EnvelopeOp` diagnostics operations.
- `testing.dart`: `FakeTransferEnvelope`, `ScriptedTransferRunner`,
  `TransfersHarness`.
