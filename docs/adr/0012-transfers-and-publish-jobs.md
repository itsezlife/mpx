# ADR 0012: Transfers and publish jobs

A new plugin, `mpx_transfer`, carries uploads and the downloads a user can
see or must keep. Each is a transfer job with one sealed state, a
`TransferId`, an opaque host tag and one observable query, all on one facade,
`Transfers`. A journal the engine owns is the source of truth: after any
kill, the engine resumes from it on the next start. Uploads go through a
host-chosen `UploadTransport` with declared capabilities; three adapters
ship. A reuse table keeps the same media from being uploaded twice. A
transfer's durability is `inProcess` or `system`, where `system` runs the
same in-process engine inside an OS envelope. A **publish job** prepares an
ordered list of items, uploads them and hands the remote references to a
registered host publisher with an idempotency key. Two seams in `mpx_core`,
`MediaPreparation` and `TrackedTransfers`, let the optional packages work
together without depending on each other. mpx knows nothing of chats,
messages or posts.

**Status**: Accepted (decided with the maintainer 2026-11-26; refined the
same day while the work was planned: preparation values in `mpx_core`, the
cache key function, download origin, the cancel path and `awaitingOwner`,
the journal writer, connectivity, the item fingerprint, a single upload,
binary sizes and the retry count)
**Relates to**: 0001, 0002, 0003, 0007, 0008, 0010, 0011
**Amends**: 0001 (package set, edges, core seams), 0007 (who owns upload),
0008 (plugin list, publish order), 0011 (video preparation limit,
`MediaPreparation`); see their amendments

## Context

The bytes cache downloads whole and ranged resources and runs file-bound GETs
on a worker isolate (ADR 0002). Nothing in mpx uploads: ADR 0007 has the host
upload a prepared file and alias the server key to the local resource
afterwards. Every host that sends media then rebuilds the same parts: split
a file into parts, keep some in flight, retry, resume after a kill, keep the
OS from suspending a long send, skip media it already sent, and show progress
on the item that is being sent.

The platforms set hard limits. No OS mechanism keeps a transfer alive after a
force quit, a Task Manager stop or a force stop, on any platform. Android 14+
offers a user-initiated data transfer job and older versions a `dataSync`
foreground service; neither may start from the background. iOS 26+ offers a
continued-processing task with a Live Activity; earlier versions give about
30 s. An out-of-process background session exists on Apple platforms but takes
uploads from a file only, one request per task. Desktop platforms and the web
offer nothing that outlives the process or the tab, and the web has no worker
isolate and no file a reload can find again.

Sending is also more than an upload. A message, a post or a profile photo
prepares several items, uploads each, then makes one request to the host's
server that names them all. That request must not run twice after a retry or a
restart.

Preparation lives in `mpx_capture` and downloads start from `mpx_core`'s
bindings, while ADR 0001 forbids an optional package to depend on another and
keeps `mpx` free of optional plugins.

## Decision

### Package and seams

`mpx_transfer` is a single plugin (ADR 0008): transfer jobs, the journal, the
reuse table, the upload scheduler with lanes, the `UploadTransport` seam and
its adapters, the query of all transfers, publish jobs, and the native part
of the OS envelope. It reuses `http_bytes_cache`'s HTTP client, retry
backoff, worker isolate and ranged sparse storage. Download bytes stay in the
bytes cache. It is an optional layer: a host that only displays media does
not link it. It runs on every platform `mpx_core` runs on.

`mpx_core` declares two seams:

| Seam | Shape | Implemented by | Taken by |
| --- | --- | --- | --- |
| `MediaPreparation` | `prepare(input, intent)` → a handle with progress, cancel and the prepared file | `mpx_capture`, over `MediaPreparer` | `PublishJob`, through its constructor. Without it only already-prepared items are accepted |
| `TrackedTransfers` | `download(key, {origin: user \| auto})`; `watch(key)` → `ValueListenable<AssetTransfer>`, `receiving` for a download and `sending` then `sent` for an upload whose source has this key; `cancel(key)`, which for an upload goes to the job's owner; `leaseFile(key)` → `Future<ContentFileLease?>` | `mpx_transfer` (`leaseFile` over the cache's `leaseFile`) | `AssetBinding`, from the cache scope (without it a download is untracked); `mpx_library`'s `MediaSaver.saveContent(keys)` |

`ContentFileLease` is an `mpx_core` value: a file path and `release()`. A
saver downloads, awaits, leases the file, saves from its path and releases
it; no edge is added.

The preparation values the first seam takes, `PreparationInput`,
`PreparationIntent` (with `CompressionPreset`) and `PreparedMedia`, are
`mpx_core` types with a stable serialisation, so the journal and the reuse
table can store them. `mpx_capture` uses them and does not re-export them.

A download's `origin` sets its default `resumeOnStart`: a `user` download
resumes at start, an `auto` one waits for a binding.

`Transfers` maps a `MediaKey` to the bytes cache's key through a
`cacheKeyOf(MediaKey)` function the composition root passes; the `mpx` stack
hands it the mapping its `BytesCacheFetcher` uses, so there is one mapping
and no edge. It serves a download's derived id, `leaseFile` and the alias.
Keys in mpx are `MediaKey`s and an item id is an opaque `String`; a host
with its own identity maps it to them.

Bindings know no jobs, directions or publish jobs. The host wires both
implementations in its composition root. `mpx_transfer` depends on
`mpx_core` and `http_bytes_cache` only; `mpx` gains no edge.

### The `Transfers` facade

| Member | Does |
| --- | --- |
| `download(key, {origin})` | A tracked download the host asks for |
| `upload(item, transport, tag)` | One upload with no publisher: a one-item publish job that completes at `uploaded` with the `RemoteRef` |
| `watch(filter)` | Snapshots of transfer jobs, by direction, state, tag and durability |
| `publish(request)` | Creates a publish job |
| `registerPublisher(id, publisher)` | Registers a publisher |
| `watchJobs(filter)` | Snapshots of publish jobs, by tag or tag prefix, publisher and state |
| `systemActive` | `ValueListenable<bool>`, true while `system` transfers run |
| `connectivityChanged(online:)` | The connectivity signal, fed by the composition root from the same device signal as the cache scope |

The queries read the journal, so they answer the same at every durability
level.

### Transfer jobs

| Area | Decision |
| --- | --- |
| Which downloads are jobs | Tracked downloads only: an `AssetBinding` with a status control that starts the content fetch, or a `download(key)` from the host or a saver. Thumbnails, previews and glyphs stay plain cache fetches |
| Identity | Every job has a `TransferId`. A download's is derived deterministically from its cache key, so a second request for the key returns the same job. An upload's is issued by the engine |
| Tag | An opaque host value on every job, so an owner finds its jobs after a restart. The engine never reads it |
| Lanes | Uploads: a small lane (photos, thumbnails, files up to 10 MiB) and a big lane (video, larger files), one job each at a time. Downloads keep the cache's priority queue (visible > preload > background) |
| Connections | One cap of 8 shared by both directions; downloads take at most 6 |
| Verbs | `pause`, `resume`, `cancel`, `retry`, `setPriority`. Cancel removes the job |
| Retention | Completed jobs stay 24 h |

`TransferState` is sealed:

| State | Meaning |
| --- | --- |
| `queued(total?)` | Accepted, not started |
| `running(done, total?, estimated)` | Bytes moving; `estimated` while the total is an estimate |
| `paused(done, total?, reason)` | Stopped, parts kept |
| `failed(kind, done, total?, retryable)` | The last attempt failed; `sourceLost` when a web upload's source did not survive a reload |
| `completed(result)` | Upload: the transport's `RemoteRef`. Download: a local file or a cache lease |

Pause reasons are a closed set:

| Reason | Entered | Left |
| --- | --- | --- |
| `user` | The user paused; a binding's cancel of a download | `resume` |
| `systemInterrupted` | The system ended the envelope | The app is in the foreground |
| `awaitingNetwork` | A transient network failure while connectivity is down (`connectivityChanged(online: false)`) | `connectivityChanged(online: true)` |
| `awaitingResume` | A download at start without `resumeOnStart` (the default for `origin: auto`) | A binding watches the key |

`TrackedTransfers.watch(key)` maps the state for surfaces: `queued` to
`waiting`; `running` to `receiving` or `sending`; `paused(user)` and
`paused(awaitingResume)` to `awaitingUser`; `paused(systemInterrupted)` and
`paused(awaitingNetwork)` to the same `receiving` or `sending` with progress
frozen, so the ring holds and cancel still works; `failed` to `failed`; an
upload's `completed` to `sent` until the publish's alias applies, then to
`none`; a download's `completed` to `none`.

### Downloads

- The job holds state; the bytes are the bytes cache's data. Parallel parts
  and ranged resume stay inside the download.
- A binding with a status control is one attached with `tracksTransfer`
  (`AssetCacheScope.attach`): `AssetView` sets it for the full and the
  compact control, which offer download and cancel, and not for the bare
  arc, which offers neither. The scope asks `download(key)` once per
  content where it would have fetched the content itself, and its attempts
  fetch only the stand-ins until the job's `watch` goes from receiving to
  `none`; then they start again and read the cached bytes.
- After a restart, `origin: user` downloads resume from the cache's data.
  `origin: auto` downloads (auto-download, a visible surface) come back
  `paused(awaitingResume)`. `resumeOnStart` overrides this per job.
- A download job fetches through the composition root's own
  `ContentFetcher` and `MediaResolver` (`TransferDownloads`), with
  `FetchRequest.whole`, so it is the cache's fetch made a job: the same
  priority queue, cap and ranged resume. `FetchRequest.priority` is fixed
  for a fetch, so `setPriority` asks again at the new priority while the
  request still waits for a slot and applies to the next run once bytes
  move; the fetch seam has no urgency below preload, so a background
  download is asked at preload.
- `binding.mapped` is reported by the `TrackedTransfers` implementation,
  which knows the job and its state, not by the binding.

### Uploads

**Source.** An `UploadSource` is a file, either finished (known size) or
growing (bytes available so far, a final size later, a head that may be
rewritten: ADR 0007's output seam). In-memory bytes go through a temp file.

**Transport.** `UploadTransport.open(info, resumeToken?)` returns a session;
`sendPart(index, offset, bytes, last)` sends one part; `finish(finalSize,
parts)` returns a `RemoteRef`, given every part's acknowledgement in index
order (a protocol that completes with the part list, such as presigned
multipart, needs them after a restart too, so the engine journals each
acknowledgement's receipt). A session may give a `resumeToken`, which the journal
keeps. Each transport declares its capabilities:

| Capability | Use |
| --- | --- |
| Part size by file size | How the engine splits the source |
| Parallel parts with a bytes-in-flight budget | How many bytes the engine keeps outstanding |
| Resume | Whether a restart reopens with the `resumeToken`, and for how long |
| Known size required | Whether a growing source waits for its final size |
| Head-last allowed | Whether a growing source's head may go last |
| `thumbnail: none \| separate` | Whether an item's thumbnail is uploaded as its own upload |
| `reuse` | Whether a stored `RemoteRef` is still valid: a lifetime, or a validity call |

The engine splits the file, keeps the budget, retries a failed part, sends the
head last for a growing source and journals each acknowledged part. Adapters
only speak their protocol. Part retries use `http_bytes_cache`'s retry backoff
with upload parameters: exponential from 1 s, each wait capped at 30 s (a
cap on one wait, not a total budget), five tries in all per part (the first
and four retries), then the transport gives up and the upload fails.

**Where requests run.** On the VM, on `http_bytes_cache`'s worker isolate,
whose client streams a request body from a file range: one HTTP stack and one
isolate for both directions. On the web, on the main thread through `fetch`
with a slice of the OPFS file or a `Blob`.

**Adapters.**

| Adapter | Shape | `thumbnail` | Resume |
| --- | --- | --- | --- |
| Multipart POST | One request with the file | `none` | None |
| tus | Resumable chunked upload | `none` | Until the server's `Upload-Expires` |
| Numbered parallel parts | Three host callbacks: start, a request for part N, complete with the acknowledgements; covers S3, R2 and GCS presigned multipart. Parts of 128 KiB (512 KiB above 10 MiB), at most about 4000 parts, 8 MiB in flight | `separate` | 1.5 h for files up to the 10 MiB lane split, 24 h above it |

A changed source or an expired window restarts the upload from zero; it does
not fail it. Download freshness stays with the bytes cache.

**Reuse table.** Re-sending the same media does not upload it again. Beside
the journal, `mpx_transfer` keeps a table from source fingerprint plus
preparation parameters to a `RemoteRef`, with the time it was stored and an
expiry. The fingerprint is the item's `fingerprint` when the host gives one
(for a library item, built from its asset id and modification date), else
path, size and mtime. The table is checked
before preparation: a hit skips preparation and upload, and the item is
`uploaded` at once. The transport judges a stored ref through its `reuse`
capability. A publisher's `reuploadItems` answer drops the entry and
re-uploads. An item whose source is a `MediaKey` that already has a server
identity (received, or aliased) goes as `remote`, with no upload. The host may
turn the table off or set its expiry.

**In the status UI.** `AssetTransfer` gains `sending(sent, total?)` and
`sent` (the upload finished, publish not yet). An `AssetBinding` reads
`TrackedTransfers.watch(key)` and shows a download or an upload in
`AssetView`'s status control: for an upload, a ring with cancel and "sent /
total". Cancel there calls `TrackedTransfers.cancel(key)`; for an upload it
drops the item from its job by the publish-job rules, and the owner sees that
through `watchJobs`. Anything more the cross means is the owner's call: a
chat drops only that item from an album. After publish,
`alias(local, server)` applies (ADR 0002) with the server keys the publisher
returns; until then the binding reads `sent`,
then it returns to `none` with the local picture kept.

### Journal

| Area | VM | Web |
| --- | --- | --- |
| Store | An append-only log in a file on the bytes cache's storage, compacted into a snapshot. No SQLite | OPFS beside the cache's store, compacted the same way. In memory only where OPFS is missing, with no resume after the tab closes |
| Writer | The main isolate, with async file IO; uploads stay on the cache's worker | The main thread; a web worker may come later without a contract change |
| Upload source | The file at its path | Copied into OPFS at job creation, up to a limit per job (default 500 MiB, the sum of its sources). Over it, or without OPFS, the job does not resume after a reload and comes back `failed(sourceLost)` |

Both: state changes are written and flushed at once; progress is batched to at
most one write per 250 ms. A kill loses at most one window; parts are
idempotent by index and offset. A record holds the `TransferId`, direction,
tag, durability, priority; source path, size, growing flag and fingerprint
(size + mtime); transport id and `resumeToken`; acknowledged parts and the
high-water mark; the OS envelope handle; created and last-progress times;
state; result.

### Durability

| Level | Promise |
| --- | --- |
| `inProcess` | Runs while the process lives; resumes from the journal on the next start |
| `system` | The same engine inside an OS envelope, so it keeps running in the background where the platform allows |

Neither level survives a force quit, a Task Manager stop or a force stop. The
journal resumes the job on the next start.

Defaults: uploads of a publish job are `system`; downloads are `inProcess`; a
host may raise a manual large-file download to `system`.

**When the envelope starts.** Per-platform defaults that the host can
override down to "always" or "never":

| Platform | Envelope and start |
| --- | --- |
| Android 14+ | A user-initiated data transfer job, started at job creation while the app is visible, for long jobs only: any item a video, or a total size over 10 MiB. Shorter jobs run `inProcess` |
| Android below 14 | A `dataSync` foreground service, same rule |
| iOS 26+ | `beginBackgroundTask` at backgrounding; a continued-processing task, its progress in the system's Live Activity
(the task's title, subtitle and progress; the host adds no widget extension),
submitted after 10 s if `system` jobs remain (`submitAt: afterDelay(10 s)`), or at resign-active (`submitAt: onResignActive`). Withdrawn when the app returns to the foreground. A refused submission degrades to `beginBackgroundTask`, then `paused(systemInterrupted)` |
| iOS below 26 | `beginBackgroundTask` (about 30 s) |
| macOS, Windows, Linux | No envelope; `inProcess`. `systemActive` tells the host that `system` transfers run, so it can confirm quitting |
| Web | `inProcess` only, with a `beforeunload` warning while transferring |

On Android one notification covers every job in the envelope, with progress
and "cancel all"; the envelope ends when its jobs drain.

**Interruptions.**

| Event | Outcome |
| --- | --- |
| The system ends the envelope (expiry, low-memory kill, a service time limit) | The engine deletes nothing. The job becomes `paused(systemInterrupted)` and resumes from the journal once the app is in the foreground. Its owner is notified and may delete instead |
| The user cancels from the notification or the Live Activity | Every job in the envelope is cancelled; owners see them removed and decide what that means |
| Force stop, Task Manager stop, force quit | No callback. On the next start the journal resumes `system` uploads; downloads follow `resumeOnStart` |
| A web reload with an upload job over the copy limit, or without OPFS | `failed(sourceLost)`; the owner may ask the user for the file again |

**Native part and host duties.**

| `mpx_transfer` owns | The host supplies |
| --- | --- |
| Android: the `JobService` for user-initiated jobs, the `dataSync` service and the shared notification. The plugin manifest declares these components and no permissions | The Android permissions `system` needs (listed in the README) and the Play Console declaration |
| iOS: task registration at launch, progress pushed every second, `beginBackgroundTask`, the `submitAt` policy | The task identifier in `BGTaskSchedulerPermittedIdentifiers` |
| Catching an OS refusal (a security exception, a scheduler refusal) and running the job `inProcess` with one debug warning | Notification and Live Activity strings and icon through `TransferEnvelopeConfig`, already localised |
| Progress mirrored from the engine; nothing is counted natively | `POST_NOTIFICATIONS` on Android 13+ to show the notification |
| | Routing of notification taps, which arrive with the job's `TransferId` |

Without a `TransferEnvelopeConfig`, `system` degrades to `inProcess` with one
debug warning.

### Publish jobs

**Request.** `transfers.publish(PublishRequest)`. The request carries a
`tag`, ordered `PublishItem`s, an opaque `payload` (bytes), a `publisher` id,
a `durability`, a `failurePolicy`, an optional `orderingGroup` and `hold`. A
`PublishItem` has an opaque `String` item id, its local `MediaKey`, an
optional `fingerprint` for the reuse table, and a source:
a `PreparationInput` with a `PreparationIntent`, an already prepared file, or
`remote` (a key that already has a server identity). A request with no items
is valid. `transfers.upload(item, transport, tag)` is the same job with one
item and no publisher; it completes at `uploaded` with the `RemoteRef`.

**Per item.** A `remote` item is `uploaded` at once. Otherwise the reuse table
is checked; a valid hit is `uploaded` at once. On a miss the item prepares
through the job's `MediaPreparation`, then uploads the file and, when the
transport's `thumbnail` is `separate`, its thumbnail as a separate upload,
and is marked `uploaded` with its `RemoteRef`s. The prepared file is
journaled: a finished preparation is not redone after a restart, an
interrupted one starts over.

**Publisher.** The host registers publishers by id at app start
(`transfers.registerPublisher(id, publisher)`). The engine calls
`publish(payload, item → remoteRefs, idempotencyKey)`, which answers a sealed
`PublishOutcome`:

| Outcome | Engine |
| --- | --- |
| `published(result, serverKeys)` | `completed(result)`; `alias(local, server)` for each entry of `serverKeys` (item id to server `MediaKey`) |
| `reuploadItems(ids)` | Drops those items' reuse entries, uploads them again, retries publish. Honoured once; a second one fails the job |
| `rejected(reason, retryable)` | `failed(stage: publish, reason)`; its retry calls publish only |

A job whose publisher is not registered waits in `awaitingPublisher`,
because a closure cannot be journaled. The request may carry an optional
`idempotencyKey`; absent, the engine makes one once per job. Either way it
is journaled and passed on every attempt.

**Failure.**

| Policy | An item fails | Retry |
| --- | --- | --- |
| `wholeJob` (default) | The job fails | Repeats only what failed; journaled uploads are kept |
| `perItem` | The item is marked; the rest go on; publish waits | The host retries the item or removes it |

Part-level network retries stay inside the upload.

**States.** Job: `preparing`, `uploading`, `publishing`, `awaitingPublisher`,
`awaitingOwner`, `paused(reason)`, `failed(stage, reason)`, `completed(result)`. Item:
`waiting`, `preparing(fraction)`, `uploading(sent, total, estimated)`,
`uploaded`, `failed`, `removed`, each with its local `MediaKey`.

**Progress.** Byte-weighted, 0..1, never decreasing; re-estimates fold in
without going back. Before preparation ends an item weighs its source size. A
video's preparation is 30 % of its item's weight; for stills and files it is
near zero. Publish takes the last 5 % of the job. A reused or `remote` item
counts as done at once.

**Observation.** `transfers.watchJobs(filter)` by tag, tag prefix, publisher
or state;
`job.watch()` and `item.watch(id)`. A media cell may skip jobs and read
`TrackedTransfers.watch(key)`.

**Ordering and hold.** Jobs that share an `orderingGroup` publish strictly in
creation order; preparation and upload stay parallel. A failed job does not
hold its group: later jobs go on, and on retry the failed job joins the end
of the group. With `hold: true` a job prepares and uploads but publishes only
on `commit(payload)`. Until then `addItem`, `removeItem`, `reorder` and
payload changes are allowed, and `cancel` drops all uploaded state. Once
publish starts only `cancel` and `removeItem` remain.

**Cancel.** Cancelling one item drops it and the rest publish. The job
reports `items.isEmpty`. A job whose last item is cancelled goes
`awaitingOwner` and publishes nothing until its owner decides; an owner
re-attaches to it after a restart through `watchJobs`. Whether it is then
cancelled is the owner's rule, since only the owner can read the payload. A
job made with no items publishes as usual.

**Preparation.** Video preparation runs one at a time app-wide and stills
and files two at a time, through the preparation policy's video limit (ADR
0011 amendment). The API admits preparation and upload overlapping on a
growing output; until `mpx_capture` emits one, an item prepares, then
uploads.

Every value in this ADR is a default the host can override.

Every path above reports structured events through `mpx_core`'s
`MpxDiagnostics`, and `transfers.debugSnapshot()` gives a debug panel the
engine's state (ADR 0013).

## Why

- The journal is written on the main isolate: its writes are small and
  batched, async file IO keeps them off the frame, and the web writes the
  same way; a journal isolate would add a second message protocol for no
  gain. Uploads, which move the bytes, stay on the cache's worker.
- A key function from the composition root keeps one `MediaKey` to cache
  key mapping, the fetcher's, without an edge to `mpx`.
- A job emptied by cancels cannot publish and cannot be judged by the engine,
  so it waits for its owner instead of publishing nothing or vanishing.
- Nothing outlives a force quit on any platform, so a journal the engine owns
  is the only state that is always there. Native queues that hold the only
  copy of a transfer lose it exactly when they are killed.
- One engine inside an OS envelope, rather than a transfer implementation per
  platform, keeps transports, retries and progress in Dart once. The native
  part only starts and stops the envelope and mirrors progress.
- Uploads are a new direction for mpx, with lanes, a source that may grow and
  a transport seam. The bytes cache stays a standalone cache by keeping them
  out, while `mpx_transfer` reuses its client, worker and storage; streaming a
  request body is the one thing its client learns.
- Seams in the core keep each optional package linkable alone: a host that
  uploads prepared files does not link the camera and encoders, and a host
  that saves media does not need `mpx` to know about transfers. A binding
  that reads one value per key, in either direction, needs no idea of jobs.
- Most downloads are thumbnails and previews nobody needs to track; making
  them jobs would fill the journal and the query with noise.
- A `TransferId` on every job, derived for downloads, gives the query and the
  notification one identity to route by.
- Over plain HTTP no protocol layer retries a part, so the engine has to; the
  cache's backoff already exists and is tested.
- The transport seam declares capabilities instead of hard-coding one
  protocol, because hosts' servers differ: a single POST, tus, or presigned
  multipart.
- Users send the same photo again and forward received media; uploading it
  again wastes their data and time, and the server already has it.
- A publisher registered by id survives a restart where a closure cannot; the
  idempotency key makes a repeated publish safe. Server keys come from the
  publish answer because only then does the host know the server's identity.
- A failed job holding its ordering group would stop every later send behind
  one bad item.
- Keeping a job on system expiry and resuming it loses no user work; an
  owner that prefers deletion can still delete.
- Permissions declared by the host keep a host that only tracks downloads
  free of foreground-service declarations and store review, as for the
  library's permissions (ADR 0011).
- On the web a reload drops every file handle, so a source the engine did not
  copy cannot be resumed; saying `sourceLost` lets the owner ask for it again.
- Byte-weighted, monotonic progress keeps a ring from jumping back when a
  compressed size replaces an estimate.

## Rejected

| Alternative | Why not |
| --- | --- |
| Uploads inside `http_bytes_cache`'s transfer worker as a whole | Puts lanes, transports and publish logic in a standalone HTTP cache; only body streaming goes there |
| A second HTTP stack or isolate for uploads | Two clients, two retry setups and two isolates for one connection cap |
| `mpx_transfer -> mpx_capture` for preparation | Every transfer host would link camera and encoder code |
| `mpx -> mpx_transfer` for saving downloaded content | Every host of the composition root would link the transfer plugin |
| A download-only binding seam | A cell would need a second path to show its own upload |
| SQLite for the journal | A native dependency and a second storage model beside the bytes cache's |
| IndexedDB for the web journal | A second web store beside the cache's OPFS data |
| Every download as a job | Thumbnails, previews and glyphs would flood the journal and the query |
| An OS-owned transfer as the default `system` path (background sessions) | Uploads from a file only, one request per task, cancelled on force quit, and no custom transport; kept as a later optional adapter |
| A second transfer implementation per platform | Two retry and progress models to keep in step |
| Counting progress natively | Two counts that disagree |
| Permissions in the plugin manifest | Every host would declare foreground-service use, including one that never asks for `system` |
| An envelope for every `system` job on Android | Short jobs finish without one, and every envelope shows a notification |
| Deleting jobs when the system ends the envelope | Loses work the journal can resume; the owner may still delete |
| Failing an upload whose source changed or whose window expired | Restarting from zero gives the user the same result without an error |
| Aliasing at upload completion | The server key is known only once the publisher answers |
| Publish callbacks as closures on the request | Cannot be journaled, so a restart would lose them |
| A journal isolate, or journal writes through the bytes cache's worker | A second message protocol for small batched writes; the web has no worker isolate anyway |
| A second `MediaKey` to cache key mapping in `mpx_transfer` | Two mappings that can disagree |
| Cancelling an empty job in the engine | The engine cannot read the payload, so it cannot tell whether anything is left to publish |
| A failed job holding its ordering group | One failure would stop every later publish in the group |
| A separate publish-jobs object beside the transfers object | Two entry points for one engine and one journal |
| No app-level part retry | Over plain HTTP nothing else retries |
| Re-uploading media already sent | Costs the user data and time for bytes the server holds |

## Consequences

- `mpx_transfer` joins the package set and `mpx_core` gains
  `MediaPreparation` and `TrackedTransfers` (ADR 0001 amendment).
- ADR 0007 is amended: `mpx_transfer` may own the upload; a host with its own
  upload still can. "Upload while converting" stays off until `mpx_capture`
  emits a growing output.
- ADR 0008 is amended: `mpx_transfer` joins the plugin list and publishes
  after `mpx_core` and `http_bytes_cache`.
- ADR 0011 is amended: the preparation policy gains a video concurrency
  limit, default 1. `mpx_capture` implements `MediaPreparation`. The
  preparation values move into `mpx_core` with a stable serialisation;
  hosts import them from there.
  `MediaSaver.saveContent(keys)` lands in `mpx_library` over
  `TrackedTransfers`, decided with the saver's own amendment.
- `http_bytes_cache`'s client learns to stream a request body from a file
  range on its worker isolate.
- `AssetTransfer` (ADR 0010) gains `sending` and `sent`; `AssetView`'s
  status control shows uploads. `mpx_core` gains `ContentFileLease` and
  `TrackedTransfers.leaseFile`. A cache scope without `TrackedTransfers`
  downloads as before.
- Hosts that use `system` durability declare the Android permissions and the
  Play Console foreground-service use, add the iOS task identifier and supply
  localised envelope strings.
- The composition root passes `Transfers` the `cacheKeyOf` mapping and its
  connectivity signal.
- A host that sends media registers its publishers at app start, before jobs
  from the last run can publish, and returns server keys from them.
- mpx's glossary gains: transfer job, tracked download, journal, upload
  transport, reuse table, durability, OS envelope, publish job, publisher.

## Settled in implementation

| Point | Settled |
| --- | --- |
| Acknowledged parts in the journal | Kept with the job's next progress write, not written one by one: a kill loses at most one window of acknowledgements, whose parts are sent again (idempotent by index and offset). Each part keeps the receipt its acknowledgement carried; the record also keeps the part size, and a transport that now declares another size starts the upload from zero. |
| Part bodies | A transport never reads the file: it receives an `UploadPartBody` whose `send(url, method, headers)` runs the engine's request (VM: a file range on the transfer worker; web: a `Blob` slice of the page's source or its OPFS copy). The engine retries; the body sends once. |
| Retries beyond parts | Opening and finishing a session are retried like a part, and report `partRetry` / `partGaveUp` with `step: open \| finish`. |
| Connections | 8 in all, downloads at most 6 and uploads at most 6 (the bytes cache's own upload cap), so neither direction holds every connection. A request holds one while on the wire and none while it waits to retry. |
| Job retryable after a give-up | `retryable: true` when the tries ran out on a failure that may pass; `false` for a refusal that cannot (a 4xx other than 408, 425 and 429, or a transport's non-transient error). |

## Open in implementation

- Platform facts not yet confirmed on devices: whether a persisted
  user-initiated job survives a reboot, whether a force stop cancels jobs
  until the next launch, and what OEM builds do to a foreground service on a
  swipe from Recents. No decision here depends on them; the journal resumes
  after any kill.
- Which `submitAt` default holds on iOS 26 devices.
- The `reuse` capability's default per adapter, and the reuse table's
  default expiry.

## Provenance

Decided with the maintainer 2026-11-26: the engine shape, durability levels,
publish jobs, the core seams in both directions, the web journal, host
permissions, the iOS submission policy, pause reasons and their triggers,
retry backoff, the facade, engine values, request placement, identities,
server keys, ordering after a failure, the thumbnail and reuse capabilities,
the publish outcome and the reuse table; and, as the work was planned, the
preparation values in `mpx_core`, the cache key function, key and item id
types, download origin, the cancel path and `awaitingOwner`, the journal on
the main isolate, connectivity, the item fingerprint, the single upload,
binary sizes, the retry count, the numbered-parts freshness boundary and the
system Live Activity. Research on upload and the outgoing
message across the messenger clients (part sizes, in-flight budgets, resume
windows, lanes, cancel and failure rules) and on background transfer APIs per
platform, with what each durability level can promise.

## Related

ADR 0002 (bytes cache, alias, worker transfers, retry backoff), 0007 (capture
output seam), 0008 (plugin shape), 0010 (`AssetTransfer`, status control),
0011 (media preparation, `MediaSaver`), 0013 (diagnostics events).
