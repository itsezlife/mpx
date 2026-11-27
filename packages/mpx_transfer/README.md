# mpx_transfer

Optional transfer jobs for mpx: uploads and the downloads a user can see or
must keep. Each job has one state, a `TransferId`, the host's opaque tag and
a durability, and every job is found through one observable query on one
facade, `Transfers`.

Early: this release holds the state model, the verbs, the query, the
journal that brings every job back after a kill, and tracked downloads.
Uploads, publish jobs and the native OS envelopes arrive in the releases
after it.

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
  // it. Ignored on the web, where the journal is in OPFS.
  directory: cacheDirectory,
  // What tracked downloads fetch through: the pipeline's own pieces.
  downloads: TransferDownloads(
    fetcher: fetcher,
    resolver: resolver,
    store: bytesStore,
  ),
);

// The core's seam over the same jobs, for the asset cache scope.
final scope = AssetCacheScope(
  producer: pipeline,
  clock: clock,
  tracked: transfers.tracked,
);

// A download the user asked for: resumes by itself after a restart.
final id = transfers.download(key);

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
- Tracked downloads: `download(key, origin:)` and `tracked`, the core's
  `TrackedTransfers`. One job per key, the bytes in the bytes cache,
  served by its priority queue; a user download resumes after a restart,
  an auto download waits (`awaitingResume`) until a surface watches it;
  `leaseFile` lends the cached file.
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
  kill is dropped.
- On the web the journal is in OPFS beside the bytes cache's store (in
  memory where the page has none). An upload's sources are copied there at
  its creation, up to 500 MiB per job (`sourceCopyLimit`), so it resumes
  after a reload; a job over the limit, or on a page without OPFS, comes
  back failed with `sourceLost`. Leaving the page asks first while a job
  is queued or running.
- Diagnostics through `MpxDiagnostics.current` (`JournalOp`,
  `SchedulerOp`, `EnvelopeOp`) and `debugSnapshot()` for a debug panel,
  with a journal section.
- `testing.dart`: `FakeTransferEnvelope`, `ScriptedTransferRunner`,
  `FakeTransferResult`, `MemoryJournalStore`, the `JournalStoreContract`
  every journal store meets, `FakeUploadSourceCopies` with the
  `UploadSourceCopiesContract`, `FakeUnloadWarning`, and
  `TransfersHarness`, which builds the engine over them and restarts or
  kills it.

## Docs

- [ADR 0012: transfers and publish jobs](../../docs/adr/0012-transfers-and-publish-jobs.md)
- [ADR 0013: diagnostics events](../../docs/adr/0013-diagnostics-events.md)
- [ADR 0001: package topology](../../docs/adr/0001-package-topology.md)
