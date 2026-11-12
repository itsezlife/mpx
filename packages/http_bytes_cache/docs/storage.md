# Storage

How `IndexedBytesCache` keeps meta fast and payloads durable. Platform
adapters implement the ports; the brain owns concurrency and retention.

## Doctrine

After open, **meta lives in a RAM mirror**. Pure reads do not hit durable meta
IO and do not run exclusive against each other. Durable meta persists with
**one commit per exclusive mutate epoch**. Payload bodies live on platform blob
stores (files on VM; Cache API and OPFS on web), never in Hive and never as
SQLite BLOB columns queried on the hot path.

Live SQL on every cache read is refused. Hive boxes for payloads are
refused.

## Ports

### `IBytesIndex`

Records per `BytesCacheKey`: `writtenAt`, `accessedAt`, `byteLength`, the
quota name (`q` in the document, left out for `images`), the payload key of an
alias row (`b`, left out when the row owns its payload), and optional HTTP
cache meta (`etag`, `lastModified`, `date`, `expires`,
`cacheControl`, `age`, `lastValidatedAt`). Those validators are not part of
key identity. `get` / `put` / `delete` / `values` mutate the RAM mirror.
`commit` writes the durable document once. Memory fakes may no-op `commit`.

### `IBytesBlobStore`

Bytes only. No timestamps. The brain pairs index rows with blobs and deletes
both on evict / TTL / trim.

Keeping the split lets prune and LRU scan sizes and access times without
loading every payload.

### Ranged resources

A ranged row (`BytesRecord.ranges` / `totalLength`) holds part of a
representation in one sparse payload. The payload port that keeps them is
`IBytesRangedBlobStore` (`writeAt`, `readAt`, `clear`); the VM store
implements it with in-place writes on the isolate worker (never temp + rename,
so a reader holding the file open sees every write; `clear` truncates in
place). Web stores do not, so `IRangedBytesStore.supportsRanges` is false
there and ranged operations throw `UnsupportedError`.

- `byteLength` is the bytes present; the row counts against `video_ranges`
  unless a write names another quota, and is evicted whole, never while
  leased (`openRanged` leases the file).
- `writeRange` with a validator other than the stored one (ETag, else
  Last-Modified) or another total length drops every span first;
  `resetRanges` does it explicitly (a `200` to a range GET).
- An incomplete ranged row is a miss for `read` / `contains` (not deleted);
  a complete one reads whole. A whole row reads as a complete ranged one.
- `writeRange` mutates RAM and the file but does not commit the index: one
  trim + commit epoch runs at most every `rangeCommitDelay` (2 s), sooner
  with any other epoch, and at close. A crash loses at most that much range
  bookkeeping, never claims bytes that were not written.

`RangedBytes` fetches into a ranged row: one shared `RangedResource` per key,
chunked single-range GETs through `HttpBytesClient.stream`, and the "range
landed" signal (`RangedEvent`) after each write. `fastStart` fetches the
head (1 MiB by default), walks the top-level MP4 boxes from offset 0 and
ensures the whole `moov`; when `moov` follows `mdat`, the walk jumps over the
media data and only the tail is fetched.

`NativeRangedReaders` (`native_reader.dart`, VM) publishes a resource to the
C reader with its key, file path and length, pushes its present spans, then
forwards every `RangeLanded` / `RangesReset` and length change over FFI. A
native read of missing bytes calls back (a `NativeCallable.listener`) and
Dart ensures at least `readAheadBytes` from there; a failed fetch wakes the
readers inside it with `HBC_ERR_FAILED`. Reads run on the player's threads,
`pread` the file outside the library's lock, and never touch the Dart
isolate.

## Concurrent reads vs exclusive mutate

`IndexedBytesCache` uses language primitives only (shared/exclusive gate).
No Mutex package.

**Shared (concurrent):** pure `read` hits and soft misses. Soft LRU writes into
`_pendingAccess` only. No `commit`.

**Exclusive (serialized writers; drain readers first):**

- `write`, `evict`, `prune`
- TTL or orphan-index deletes upgraded from a shared `read` probe
- `reclaimOrphans`
- `close`

Mutate epoch shape:

```text
exclusiveMutate:
  snapshot RAM mirror (last-good meta)
  flush soft access into RAM map
  apply puts / deletes / trim (including blob IO)
  commitDurableMetaOnce   // on throw: restore RAM from snapshot, rethrow
  reclaimOrphanBlobs(indexedKeys)   // prune and explicit reclaim
```

Without the single-commit rule, a soft-LRU flush that touches N keys would
rewrite the durable index N times. Without the shared exclusive domain, orphan
reclaim can delete a blob mid-write. Open wrappers must pass reclaim into the
brain; they must not reclaim outside that gate.

If `commit` throws after RAM (and possibly blob) mutation, the brain restores
the RAM mirror to the pre-epoch snapshot and rethrows. We picked that over
fail-closing the instance, and over leaving a "write failed but RAM hit"
lie. Blob IO is not rolled back. A failed write may leave an orphan blob. A
failed commit after trim, evict, or TTL may put index rows back whose
payloads are already gone; the next read heals those as index-without-blob,
and those previously durable bodies stay gone. Resolve write-through still
reports the thrown write via diagnostics and does not fail paint.

After `close`, Indexed ops throw `StateError`. Platform wrappers close isolate
or Cache/OPFS handles around the brain.

## Soft LRU

Access times update in memory on successful read. They flush into the RAM
index at the start of a mutate epoch (`write` / `prune`), then one `commit`
persists them with any other meta changes. Paint does not force durable meta
IO.

## Retention

Sealed `BytesRetention`: the store's whole budget. Age counts from **last
use** (`accessedAt`, including a soft access not yet flushed), not from the
write, and is checked on `read`. Capacity is trimmed on `write` and `prune`.
There is no background eviction timer.

`BytesRetention.standard` (default for `open`):

| Limit        | Value   |
| ------------ | ------- |
| `maxAge`     | 30 days since last use |
| `maxEntries` | 10 000  |
| `maxBytes`   | 1 GiB   |

The entry cap bounds the index document each commit rewrites; the byte budget
bounds the disk without a timer.

### Quotas

Every row belongs to a named `BytesQuota` (`write(…, quota:)`,
`BytesRequest.quota`; null keeps the row's quota, else `images`).
`BytesQuota.standard`:

| Quota           | `maxBytes` |
| --------------- | ---------- |
| `images`        | 256 MiB    |
| `video_ranges`  | 768 MiB    |
| `lottie_frames` | 256 MiB    |
| `glyphs`        | 32 MiB     |

One eviction pass plans from one listing of the index: each quota over its own
limits gives back its least recently used rows; then, while the store is over
its budget, the quota with the highest bytes-used / `maxBytes` gives back one
row at a time. Leased rows are never candidates. A quota the store was not
configured with brings its own limits on write.

A registered quota (`registerQuota(quota, onEvict:)`) adds an owner's reported
bytes to its quota and to the total. When that quota must give back space the
store calls `onEvict(bytesNeeded)` inside the exclusive domain and takes the
returned count off its usage; an owner that frees nothing (or throws, reported
as `quota_evict`) is not asked again in that pass. A usage report schedules
one coalesced eviction pass. The store never lists, reads or deletes the
owner's files; orphan reclaim only touches top-level files, so an owner folder
inside the store directory is safe. Hosts may pass `compound`, `maxAge`,
`maxEntries`, `maxBytes`, or `unlimited`. When set, `maxEntries` and
`maxBytes` must be **positive** (asserted on the retention constructors);
non-positive caps are nonsense policy.

Empty payloads are not retained on `write` (treated as eviction of that key).
A sticky empty durable row still misses on `read` and is scrubbed so it cannot
waste entry capacity.

Capacity trim evicts least-recently-accessed records after soft access has
been flushed, so a just-read entry is not wrongly dropped when writing a new
one under `maxEntries`.

## Orphans

| Case               | When                              | Action                                           |
| ------------------ | --------------------------------- | ------------------------------------------------ |
| Index without blob | Shared `read` probe               | Upgrade to exclusive; delete index row; `commit` |
| Blob without index | Open / `prune` / `reclaimOrphans` | Platform reclaim under exclusive gate            |

Remote bytes are disposable: corrupt recovery prefers wipe over crash loops.

## Index document

`BytesIndexDocumentCodec` owns the wire shape for VM file and web meta
Cache:

```text
{"v":1,"e":{"<key>":{"w":ms,"a":ms,"n":byteLength,"q"?,"b"?,"r"?:[s0,e0,…],"t"?:total,"h"?:{"et","lm","d","x","cc","ag","lv"}}}}
```

`r` and `t` appear on ranged rows only (merged half-open spans, total length).

Optional `h` is HTTP validators and freshness (`HttpCacheMeta`). A missing
`h`, or missing keys inside it, decodes as null meta. Existing caches that
never wrote `h` keep working. Empty meta is omitted on encode. Version stays
`1` while the schema stays backward-compatible. Freshness decisions use
`HttpCacheFreshness`; durable eviction still uses `BytesRetention`
only. Do not treat retention TTL as Cache-Control `max-age`.

Unknown version or bad structure throws `FormatException`. Open paths delete
the document, wipe blobs via `onWipe`, and report `index_wipe`. Adapters must
encode and decode through the codec (fused UTF-8 JSON converters), not peel
`jsonEncode` / `utf8.encode` at call sites.

## VM durable path

| Half  | Implementation                                                        |
| ----- | --------------------------------------------------------------------- |
| Index | Versioned JSON file; RAM mirror; `commit` via the blob isolate worker |
| Blobs | One file per `BytesCacheKey.value` under the open directory           |

IO runs on a long-lived in-package `IsolateController` worker
(`lib/src/isolate_controller.dart`). Sync `dart:io` stays off the UI
isolate. Writes use temp then rename so a crash mid-write cannot leave a
truncated final path that `read` would treat as a hit.

When the worker dies (watchdog threshold, handler `#exit`, or an explicit
kill), `BytesBlobStore$File$VM` fails in-flight RPC futures with
`StateError`, drops the dead controller, and allows a later op to respawn.
That fail-fast path keeps the exclusive mutate gate from stalling forever on
a hung blob future. Store `close` still fails pending with a closed
`StateError` and refuses further RPCs.

Bodies at or above `BytesBlobStore$File$VM.transferByteThreshold`
(64 KiB) cross the isolate boundary as `TransferableTypedData`. Smaller bodies
stay plain `Uint8List` (transferable setup would cost more than it saves).
No per-write `compute`.

`directory` is required on VM and should sit under the app **cache** root
(reclaimable), not documents/support.

## Web durable path

| Half                     | Implementation                                                   |
| ------------------------ | ---------------------------------------------------------------- |
| Index                    | One Cache API JSON document (`BytesWebKeys.indexCacheName`) |
| Blobs under 64 KiB       | Cache API Responses with synthetic `.invalid` URLs               |
| Blobs at or above 64 KiB | OPFS files under `opfsBlobsDirectoryName`                        |

`BytesBlobStore$Routed$JS.opfsByteThreshold` is 64 KiB, matching the VM
transferable cut so small and large bodies share one documented size policy.
Writes route by length and delete the key from the other backend so a
resize across the threshold cannot leave a stale twin. Reads use the RAM index
`byteLength` when the brain already probed it: at or above the threshold they
go straight to OPFS (no Cache match tax); otherwise they check Cache then OPFS.

Synthetic keys use host `image-bytes.invalid` so payload entries never share
identity with real network fetches and never invite accidental Cache `add()`
network hits. OPFS filenames are `BytesCacheKey.value` (already filename-safe).
No `IsolateController` on web.

API parity with VM means the same `IBytesCache` contract. Cost asymmetry
is expected: web is not a second copy of the isolate worker model.

## Memory and NoOp

`MemoryBytesCache` is an in-process map for tests and degraded open.
Access times update on every read (cheap in memory). Optional
`HttpCacheMeta` sits on the same entry as the bytes, so `readRich` and
middleware `execute` can return it. `close` is a no-op; the instance stays
usable so tearDown can call `close` uniformly.

`NoOpBytesCache` always misses and discards writes. It is the default
`shared()` until bootstrap configures a real store. `close` is a no-op.

Neither is a durable platform backend.
