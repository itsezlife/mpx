# mpx_transfer

Optional transfer jobs for mpx: uploads and the downloads a user can see or
must keep. Each job has one state, a `TransferId`, the host's opaque tag and
a durability, and every job is found through one observable query on one
facade, `Transfers`.

Early: this release holds the state model, the verbs, the query, the
journal that brings every job back after a kill, tracked downloads,
uploads, publish jobs and the Android and iOS OS envelopes.

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
  // The same MediaKey to cache key mapping the bytes cache fetcher uses,
  // and where server keys are aliased after a publish (downloads.store
  // when omitted).
  cache: TransferBytesCache(keyOf: (key) => key.encoded, store: bytesStore),
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
  // snapshot.progress: 0..1, byte-weighted, never goes back.
});

// Every job of one conversation, after a restart too.
transfers
    .watchJobs(PublishJobFilter(tagPrefix: 'chat:$chatId:'))
    .listen((jobs) { /* banners, bubbles */ });

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

// The OS envelope's text and icon, already localised by the host. Without
// a config `system` jobs run in process. Host setup: "Android" and
// "iOS" below.
//   Transfers.open(...,
//       envelope: TransferEnvelopeSetup(
//         Platform.isAndroid ? AndroidTransferEnvelope() : IosTransferEnvelope(),
//         config: TransferEnvelopeConfig(
//           title: l10n.sendingMedia,
//           cancelAllLabel: l10n.cancelAll,
//           progressText: (p) => l10n.filesLeft(p.jobs.length),
//         ),
//       ));
// A tap on the envelope's notification arrives with the job's id.
transfers.notificationTaps.listen(openChatFor); // the host routes

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

## Android

`AndroidTransferEnvelope` keeps `system` jobs running with the app in the
background and the screen off: a user-initiated data transfer job on
Android 14 and later, a `dataSync` foreground service before, with one
notification for every job inside it (the engine's progress, "cancel all",
a tap that opens the app and arrives on `notificationTaps`). It starts when
a long job is created while the app is visible (a video, or more than
`longJobBytes`, 10 MiB), and ends when its jobs drain.

The plugin's manifest declares the job service, the foreground service and
the cancel receiver, and no permissions. A host that wants `system`
transfers adds them to its own `AndroidManifest.xml`:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.INTERNET" />
    <!-- Android 14 and later: the user-initiated data transfer job. -->
    <uses-permission android:name="android.permission.RUN_USER_INITIATED_JOBS" />
    <!-- Before Android 14: the dataSync foreground service. -->
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" />
    <!-- Android 13 and later: the notification in the drawer (without it
         the job shows in the Task Manager only). Ask for it at run time. -->
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
</manifest>
```

Without them the platform refuses the envelope; the plugin catches the
refusal (`envelope` `refused`, then `degraded`) and the jobs run in
process. An app published on Google Play that targets Android 14 or later
also declares the `dataSync` foreground service type in Play Console
(App content, Foreground service permissions): a short description of the
user-started upload, the impact of deferring it, and a video of a user
starting a transfer and the notification that follows.

The notification's title, text, "cancel all" label, progress line and
small icon (a drawable or mipmap name) come from `TransferEnvelopeConfig`;
the title also names the notification channel. The system ends the
envelope after a time limit, a quota or a lost network, which pauses its
jobs `systemInterrupted`; a low-memory kill is reported at the next start.
The native side logs every envelope event to logcat (tag `mpx_transfer`)
and, while Dart is not running, to a ring file of at most 2 MiB
(`nativeLogBytes`), merged into diagnostics at the next start.

## iOS

`IosTransferEnvelope` holds the process for `system` jobs once the app
leaves the foreground: a background task (about 30 s), and on iOS 26 and
later a continued-processing task whose title, text and progress the
system shows in a Live Activity (no widget extension). Features below.

For `system` transfers in the background on iOS 26 and later, the app's
`Info.plist` names the task identifier and the background mode. Without
the identifier the background task (about 30 s) still holds the process,
and each submission is reported refused (`noIdentifier`).

```xml
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
  <string>$(PRODUCT_BUNDLE_IDENTIFIER).mpx.transfer.*</string>
</array>
<key>UIBackgroundModes</key>
<array>
  <string>processing</string>
</array>
```

The plugin registers each task under that prefix itself. iOS 15 is the
floor; an app built with an SDK older than iOS 26's has the background
task only.

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
- Uploads seen by content key through the same `tracked`: a publish job
  item's local key reads `waiting`, `sending` (held while the system or
  the network paused it), `sent` until its job published and aliased its
  server keys, then `none`, the local picture kept. `cancel(key)` removes
  the item from its job (`by: cell`); `download(key)` resumes or retries
  it.
- Uploads through any `UploadTransport`: the engine splits the file by the
  transport's part size, keeps its bytes-in-flight budget, retries a part
  five tries in all, journals every acknowledged part and resumes with the
  transport's token after a restart, sending only what is missing, while
  the file is unchanged and the transport's window open; otherwise the
  upload starts again from zero, never failing for it. Its bytes done
  never go back, through a retry or a restart from zero. Two
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
  `rejected(reason, retryable)` fails the job at the publish stage. A
  publisher that throws fails it the same way, retryable, with
  `PublishFailureReason.publisherError`; a failed job or item names its
  `PublishFailureReason` (the engine's own codes, an upload's failure
  kind, a preparation's code or the publisher's reason).
- Failure policies and retry: `wholeJob` (default) fails the job with an
  item, `perItem` lets the rest upload and holds the publish.
  `PublishJob.retry()` / `retryItem(id)` repeat only what failed, keeping a
  finished preparation and the parts already sent; a job rejected at the
  publish stage publishes again and uploads nothing.
- Ordering groups: jobs that share an `orderingGroup` publish in the order
  they were made, while preparation and upload stay parallel. A failed job
  holds no one; retried, it goes to the end of the group.
- Hold and commit: a `hold: true` job prepares and uploads, and publishes
  on `commit(payload:)`. Until then `addItem`, `removeItem`, `reorder`,
  `setPayload` and `cancel` apply (`snapshot.held`); once it publishes,
  only `removeItem` and `cancel`.
- Payload for the owner: `PublishJob.payload` and `snapshot.payload` (also on
  what `watchJobs` gives) read the job's bytes from its record: the
  request's, or the last `setPayload` or `commit(payload:)`, after a restart
  too. They stay out of diagnostics.
- Item cancel: `removeItem(id)`, or a cancel of one of the item's uploads,
  drops the item and the rest publish. A job left with no items is
  `awaitingOwner` and publishes nothing, after a restart too, until its
  owner commits or cancels it. `PublishJob.cancel()` removes a job in any
  state, with its uploads.
- Publish progress: each job and item snapshot carries a `progress`,
  0..1, byte-weighted (an item weighs its source until its preparation
  ends, then its upload's bytes), a video's preparation 30 % of its item
  and a still's or a file's 2 %, the publisher's call the last 5 % of the
  job; a remote item or a reuse hit is done at once. A re-estimate never
  lowers it, and a restart starts from what the journal kept.
  `Transfers.open(progressWeights:)` sets the shares
  (`PublishProgressWeights`).
- `watchJobs(filter)`: snapshots of the publish jobs a `PublishJobFilter`
  passes (tag, tag prefix, publisher, state), answered from the journal
  after a restart.
- `retry(id, source:)`: an upload whose source was lost goes again, from
  zero, from a `SourceBytes` the host gives: a file on the VM
  (`SourceBytes.file`, or bytes in memory written to a file of the
  engine's own), the picked file again on the web.
- `TransferDurability`: `inProcess`, or `system` inside the platform's OS
  envelope (`TransferEnvelope`) where there is one. Publish job uploads
  are `system`, downloads `inProcess` unless the host raises one.
- The envelope starts by the platform's rule (`long`: a video or more than
  10 MiB over a publish job's uploads; `always`), which the host's
  `TransferEnvelopeConfig.startRule` overrides down to `never`; shorter
  jobs join one a long job started. It stops when its jobs drain, and its
  handle is journaled with each job, so after a kill the next start takes
  over an envelope the native part still holds. A refused start runs the
  jobs in process. When the system ends it, its jobs pause
  `systemInterrupted` and resume in the foreground; nothing is deleted.
  "Cancel all" from the system's UI cancels every job in it, and each
  publish job one of them belongs to. `notificationTaps` streams the job a
  tapped notification showed. `debugSimulateSystemInterruption()` (debug
  builds) acts out a system end for a debug panel.
- iOS (`IosTransferEnvelope`): a background task begun the moment the app
  enters the background (about 30 s, every version); on iOS 26 and later a
  continued-processing task, whose progress the system shows in a Live
  Activity with the config's title and text (no widget extension), asked
  for 10 s after backgrounding while `system` jobs remain
  (`submitAt: afterDelay`), or at resign-active (`onResignActive`).
  Progress is pushed every second while it changes. Everything is let go
  when the app returns to the foreground. A refused submission keeps the
  background task; when that time ends, or the system ends the
  continued-processing task, the jobs pause `systemInterrupted`. A cancel
  in the Live Activity looks the same to the app as a system stop, so it
  pauses the jobs too. Native events also go to `os_log` (subsystem
  `dev.mpx.transfer`, category `envelope`) and, while no Dart side is
  attached, to a ring file of at most 2 MiB, emitted at the next start.
- `Transfers.watch(filter)` by direction, state, tag and durability; a
  completed job stays queryable for 24 hours (`retention`).
- `pause`, `resume`, `cancel`, `retry`, `setPriority`, and
  `connectivityChanged(online:)`.
- A journal on the device: an append-only log beside the bytes cache,
  folded into a snapshot at each start. A state change is written and
  flushed at once, progress at most every 250 ms (`progressInterval`), so
  a kill loses at most one window of progress; a record cut short by a
  kill is dropped. A remote end's finish answer is written before the
  upload completes, so a kill in between never finishes it twice; a
  finish the remote end refuses after a restart sends the upload again.
  Publish jobs and the reuse table are kept the same way.
- On the web the journal is in OPFS beside the bytes cache's store (in
  memory where the page has none). An upload's sources are copied there at
  its creation, up to 500 MiB per job (`sourceCopyLimit`), so it resumes
  after a reload; a job over the limit, or on a page without OPFS, comes
  back failed with `sourceLost`. Leaving the page asks first while a job
  is queued or running.
- Page sources: a publish item uploads a picked file the page holds
  (`PublishItem.pageSource`, `SourceBytes.blob(file)`) or prepared bytes
  (`PreparedMedia.bytes`). On the web they are copied into OPFS as above;
  an item whose copy is gone after a reload fails with `sourceLost`, and
  `job.retryItem(itemId, source:)` takes the file picked again. On the VM,
  bytes with no file at the media's path are written to a file of the
  engine's own, deleted once the job ends.
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
