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
  // What uploads and publish jobs go through (the first is the default),
  // the bytes cache's client that sends their parts, and the preparation
  // seam (mpx_capture's CaptureMediaPreparation) for items that need it.
  transports: [presigned],
  client: httpBytesClient,
  preparation: preparation,
  // Where server keys are aliased after a publish (downloads.store when
  // omitted).
  cache: bytesStore,
);

// At app start, before jobs from the last run can publish.
transfers.registerPublisher('chat.send', ChatSendPublisher(api));

// Prepare, upload, then publish once with one idempotency key.
final job = transfers.publish(PublishRequest(
  tag: 'chat:7:m-42',
  items: [
    PublishItem(
      itemId: 'm-42/0',
      key: localKey,
      source: PublishSource.prepare(
        PreparationInput(pickedPath),
        const PreparationIntent.photo(),
      ),
      fingerprint: libraryFingerprint, // optional; path + size + time else
    ),
  ],
  payload: utf8.encode(jsonEncode(message)),
  publisher: 'chat.send',
  idempotencyKey: clientMessageId, // optional; the engine makes one else
));
job.watch().listen((snapshot) {
  // snapshot.state: preparing, uploading, publishing, completed ...
});

// One upload, no publisher: completes once the item is uploaded.
final avatar = transfers.upload(
  PublishItem(
    itemId: 'avatar',
    key: avatarKey,
    source: PublishSource.prepared(prepared),
  ),
  tag: 'profile:avatar',
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

// A transport for a server that takes the file in one multipart POST.
final multipart = MultipartUploadTransport(
  request: (info) => MultipartUploadRequest(
    uploadUrl,
    headers: {'authorization': 'Bearer $token'},
    fields: {'album': '7'},
  ),
  remoteRef: (response) => RemoteRef(parseFileId(response.body!)),
);

// A transport for S3, R2 or GCS presigned multipart: the host's server
// creates the upload, presigns each part's PUT and completes it.
final presigned = NumberedPartsTransport.presignedMultipart(
  start: (info) => api.createUpload(info.size), // key and upload id
  partRequest: (part) async => NumberedPartRequest(
    await api.presignPart(part.uploadId, part.number),
  ),
  complete: (completion) async => RemoteRef(
    await api.completeUpload(completion.uploadId, completion.parts),
  ),
);

// A transport for a tus server: resumable, from the server's offset.
final tus = TusUploadTransport(
  endpoint: Uri.parse('https://uploads.example.com/files/'),
  client: httpBytesClient,
);

// Verbs on one job (`id`, a `TransferId` from a snapshot) answer whether
// it changed.
transfers.pause(id);
transfers.resume(id);
transfers.retry(id);
transfers.cancel(id); // removes it

// On macOS, Windows and Linux there is no OS envelope: quitting ends every
// job. `systemActive` is true while a `system` job is queued or running, so
// the host can ask before it quits. (Defined on every platform.)
if (transfers.systemActive.value) {
  final quit = await confirmQuit(); // the host's own dialog
  if (!quit) return;
}
transfers.systemActive.addListener(() {
  // e.g. show or hide a "transfers running" hint
});
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
- Uploads through any `UploadTransport`: the engine splits the file by the
  transport's part size, keeps its bytes-in-flight budget, retries a part
  five tries in all, journals every acknowledged part and resumes with the
  transport's token after a restart, sending only what is missing, while
  the file is unchanged and the transport's window open; otherwise the
  upload starts again from zero, never failing for it. Two
  lanes (small up to 10 MiB, big), one job each, under 8 shared
  connections. A completed upload holds a `RemoteRef`.
- `MultipartUploadTransport`: the file in one `multipart/form-data`
  request, with the host's URL, headers and form fields per upload.
- `NumberedPartsTransport`: numbered parts in parallel through three host
  calls (start, a request for part N, complete with every part's
  acknowledgement); resumes within 1.5 h (24 h above 10 MiB). Parts of
  128 KiB (512 KiB above 10 MiB), 8 MiB in flight; `presignedMultipart`
  for S3, R2 and GCS with 8 MiB parts.
- A reuse table (`reuse`): an upload's references kept by source and
  transport, so the same media sent again skips preparation and upload
  while the transport judges them good; on by default for 7 days
  (`ReusePolicy`), kept beside the journal.
- `TusUploadTransport`: the tus resumable upload protocol; a restart
  sends only what the server lacks, an expired or forgotten upload starts
  again from zero.
- Publish jobs (`publish(request)`, `registerPublisher(id, publisher)`,
  `publishJob(id)`): an ordered list of items, each looked up in the reuse
  table, sent as remote, prepared through `MediaPreparation` or taken as
  already prepared, then uploaded (its thumbnail as an upload of its own
  for a transport that takes thumbnails separately), then the registered
  `Publisher` called once with every item's references, the payload and
  one idempotency key. A job whose publisher is not registered waits, after
  a restart too. Every step is journaled beside the journal; a finished
  preparation is never redone, an interrupted one starts over.
  `PublishJob.watch()` and `watchItem(id)` stream snapshots;
  `upload(item)` is a one-item job with no publisher.
- Publisher answers (`PublishOutcome`): `published(result, serverKeys)`
  completes the job, then aliases each server key to its item's local key
  in the bytes cache (`snapshot.aliasesApplied`); `reuploadItems(ids)`
  drops those items' reuse entries and sends them again, once per job;
  `rejected(reason, retryable)` fails the job at the publish stage.
- Failure policies and retry: `wholeJob` (default) fails the job with an
  item, `perItem` lets the rest upload and holds the publish.
  `PublishJob.retry()` / `retryItem(id)` repeat only what failed, keeping a
  finished preparation and the parts already sent; a job rejected at the
  publish stage publishes again and uploads nothing. `removeItem(id)` drops
  an item before the publish.
- `retry(id, source:)`: an upload whose source was lost goes again from a
  file the host gives, from zero.
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
  `SchedulerOp`, `TransportOp`, `EnvelopeOp`, `ReuseOp`, `PublishOp`,
  `PublishPreparationOp`) and `debugSnapshot()` for a debug panel, with
  journal, uploads, connections, reuse and publish sections.
- `testing.dart`: `FakeTransferEnvelope`, `ScriptedTransferRunner`,
  `FakeTransferResult`, `MemoryJournalStore`, the `JournalStoreContract`
  every journal store meets, `FakeUploadSourceCopies` with the
  `UploadSourceCopiesContract`, `FakeUnloadWarning`, `FakeUploadTransport`
  with the `UploadTransportContract` every transport meets, the
  `ReuseTableContract` the reuse table meets over every store,
  `FakePublisher`, answering each call on script, `UploadsHarness`, which
  runs uploads and publish jobs through the real engine, and `TransfersHarness`, which builds the engine over
  them and restarts or kills it.

## Docs

- [ADR 0012: transfers and publish jobs](../../docs/adr/0012-transfers-and-publish-jobs.md)
- [ADR 0013: diagnostics events](../../docs/adr/0013-diagnostics-events.md)
- [ADR 0001: package topology](../../docs/adr/0001-package-topology.md)
