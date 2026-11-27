# mpx_transfer

Optional transfer jobs for mpx: uploads and the downloads a user can see or
must keep. Each job has one state, a `TransferId`, the host's opaque tag and
a durability, and every job is found through one observable query on one
facade, `Transfers`.

Early: this release holds the state model, the verbs, the query and the
journal that brings every job back after a kill. Downloads, uploads,
publish jobs and the native OS envelopes arrive in the releases after it.

## Install

Not published yet. Depend on it from git:

```yaml
dependencies:
  mpx_transfer:
    git:
      url: https://github.com/itsezlife/mpx.git
      path: packages/mpx_transfer
```

## Usage

```dart
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_transfer/mpx_transfer.dart';

// In the composition root, once the app runs. Reads back the jobs the
// last run left, whether it closed or was killed.
final transfers = await Transfers.open(
  // The same MediaKey to cache key mapping the bytes cache fetcher uses.
  cacheKeyOf: (key) => key.encoded,
  lifecycle: WidgetsPlaybackLifecycleSource(),
  // The bytes cache's directory; the journal sits in `mpx_transfer` below
  // it. Ignored on the web.
  directory: cacheDirectory,
);

// Fed from the device signal the asset cache scope reads.
transfers.connectivityChanged(online: false);

// Every paused job of one owner.
transfers
    .watch(TransferFilter(
      tag: 'post:42',
      state: (state) => state is TransferState$Paused,
    ))
    .listen((jobs) {
      for (final job in jobs) {
        // job.id, job.state, job.durability ...
      }
    });

// Verbs on one job (`id`, a `TransferId` from a snapshot) answer whether
// it changed.
transfers.pause(id);
transfers.resume(id);
transfers.retry(id);
transfers.cancel(id); // removes it
```

## Features

- `TransferState`: `queued`, `running` (bytes done, total, estimated),
  `paused` with a `PauseReason` (`user`, `systemInterrupted`,
  `awaitingNetwork`, `awaitingResume`), `failed` with a
  `TransferFailureKind` (`sourceLost` included) and `completed`. A cancel
  removes the job; there is no cancelled state.
- `TransferId`: a download's is derived from its cache key, so one key has
  one job; an upload's is new for every job.
- `TransferDurability`: `inProcess`, or `system` inside the platform's OS
  envelope (`TransferEnvelope`) where there is one.
- `Transfers.watch(filter)` by direction, state, tag and durability; a
  completed job stays queryable for 24 hours (`retention`).
- `pause`, `resume`, `cancel`, `retry`, `setPriority`, and
  `connectivityChanged(online:)`.
- A journal on the device: an append-only log beside the bytes cache,
  folded into a snapshot at each start. A state change is written and
  flushed at once, progress at most every 250 ms (`progressInterval`), so
  a kill loses at most one window of progress; a record cut short by a
  kill is dropped. On the web it is in memory until the OPFS store lands.
- Diagnostics through `MpxDiagnostics.current` (`JournalOp`,
  `SchedulerOp`, `EnvelopeOp`) and `debugSnapshot()` for a debug panel,
  with a journal section.
- `testing.dart`: `FakeTransferEnvelope`, `ScriptedTransferRunner`,
  `FakeTransferResult`, `MemoryJournalStore`, the `JournalStoreContract`
  every journal store meets, and `TransfersHarness`, which builds the
  engine over them and restarts or kills it.

## Docs

- [ADR 0012: transfers and publish jobs](../../docs/adr/0012-transfers-and-publish-jobs.md)
- [ADR 0013: diagnostics events](../../docs/adr/0013-diagnostics-events.md)
- [ADR 0001: package topology](../../docs/adr/0001-package-topology.md)
