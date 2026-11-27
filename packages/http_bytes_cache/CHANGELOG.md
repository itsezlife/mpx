# Changelog

## Unreleased

- `HttpBytesClient.upload`: a `POST`, `PUT` or `PATCH` whose body streams
  from a byte range of a file (`HttpBytesUploadBody.file`), or on the web of
  a `Blob` (`HttpBytesUploadBody.blob`). On the VM the transfer worker reads
  the range and sends it, so the bytes never enter the calling isolate and
  a 50 MiB body goes out through a bounded buffer; a client given no
  `HttpBytesTransfers` spawns the worker with the defaults for it. On the
  web the slice goes to `fetch` (a path names an OPFS file). The answer's
  status, headers and small body come back. `onBytesSent` reports the bytes
  sent at the transfers' cadence; the `CancelToken` aborts the body or a
  wait between tries. `retry` retries transient failures and timeouts;
  `HttpBytesRetryBackoff.uploadPart` is the preset for parts: five tries in
  all, waits from 1 s, each capped at 30 s.
- `HttpBytesUploadBody` takes a `prefix` and a `suffix`: small bytes sent
  before and after the range (a multipart form's framing). `contentLength`
  is the whole body, which the request's `Content-Length` and
  `onBytesSent` count.
- `HttpBytesRetryBackoff.minDelay`: a floor under every jittered wait
  (zero by default, which keeps full jitter and the same delays as before).
- One connection cap for both directions: `maxConcurrent` is now 8 in all,
  of which GETs take at most `maxDownloads` (6) and uploads at most
  `maxUploads` (6), so each direction keeps 2 however busy the other is.
  A client that only GETs still runs 6 at once; one built with
  `maxConcurrent: n` below 6 runs `n` as before.
- `BytesLogEvent.fields`: structured detail (numbers and short strings, no
  URL, header or path). Uploads report `BytesLogOp.uploadStarted`,
  `uploadRetry` (with the attempt and the delay) and `uploadGaveUp`.

- A transfer aborted before or while its body is written no longer surfaces
  as an uncaught error. A download cancelled between its head and its write
  (a preload whose item left the window, a tile scrolled away) failed the
  worker's body future with `TransferFailed(cancelled)` while nothing listened
  to it, and the zone reported it, once for each such transfer. The failure
  now travels as a value and is thrown to the write that asks for it.
- `BytesQuota.previews` (4 MiB), one of `BytesQuota.standard`, for small
  derived preview pictures.
- Ranged resources download in parts, several in flight at once: each part
  is a range GET written at its offset as it arrives, so parts land in any
  order and a reader waits only for the bytes it asked for. `RangedParts`
  sets the part size (512 KiB, split down to 128 KiB for a short ask) and
  the parts per resource (4); the client's slots cap the total. The part
  at an ask's first missing byte goes first; the parts ahead of it queue
  one priority lower. A cancelled ask keeps the parts that landed. An ask
  to the end learns the length from its first part, then goes on in parts.
- `RangedResource.ensure(streaming: true)`: a reader moving forward as the
  media plays asks one whole part at a time, with no parts ahead. The
  native reader's asks are streaming, so playback sends as many requests
  as before, and a reader leaving the screen stops one GET, not four.
- Breaking: `RangedBytes(chunkBytes:)` is now
  `RangedBytes(parts: RangedParts(partBytes:))`.
- Native reader, ABI 3: `hbc_reader_available` (`NativeRangedReader.available`)
  says which bytes are there without waiting and asks for the rest as a
  hint (`HBC_FETCH_HINT`); `NativePublication.stopHints` stops the hints of
  a reader that stopped reading, keeping what landed. Versions only append
  to the `hbc_api` table.
- Ranged resources: an ask more than 32 KiB past a running GET's next byte
  gets a GET of its own, so the index at the end of a file is fetched before
  the body that comes before it.
- `HttpBytesClient(transfers: HttpBytesTransfers())` and
  `HttpBytesClient.transfer`: a GET whose socket, body and file writes run
  on a worker isolate, the calling isolate hearing only the head and each
  span written (VM only; `canTransfer` says whether it is on).
  `HttpBytesTransfers.onTransfer` reports each one when it ends.
- Ranged resources fetch through transfers when the client offers them and
  the store keeps files, recording the spans with the new
  `IRangedBytesStore.recordRange`; the bytes never enter the calling
  isolate.
- The VM store's reads above 64 KiB come back as a transferable, so the
  reading isolate no longer copies the payload out of the message.
- `BytesCacheKey.within(owner, url)`: one key per URL under an owner's key,
  for the playlists and segments of a stream.
- Emptying a ranged payload puts a new file in its place instead of
  truncating it. A native reader of an alias keeps the bytes it opened
  while the local key is rewritten; a key's own readers reopen the file
  after a reset, and no longer read new bytes at old offsets before the
  reset reaches them.
- Ranged resources: opening an alias of complete bytes (a captured file
  aliased to its server key) reads them in place instead of fetching the
  server's copy; `readRange` and `rangesOf` follow the alias too.
- An alias is a snapshot: rewriting or resetting the local key, before or
  after `release`, leaves the server key with the bytes and length it had.
- `registerQuota` refuses limits that differ from the configured quota of
  the same name, instead of dropping them silently.
- Breaking: `BytesRecord.quota` and `BytesQuota.name` are a
  `BytesQuotaName`.
- Native reader: a key published twice stays readable until each of its
  publications closes.
- Native reader: a read that races a ranges reset waits for the bytes to
  land again instead of failing with `HBC_ERR_IO`.
- Native reader: one `NativeRangedReaders` per process, enforced natively;
  a second one in any isolate throws `StateError`. `hbc_set_fetch_callback`
  is replaced by `hbc_attach` / `hbc_detach`; `HBC_ABI_VERSION` is 2.
- Native reader: an instance dropped by a hot restart is detached and its
  resources withdrawn as its isolate group shuts down.
- Ranged resources: a long-lived cancel token no longer keeps a listener
  per landing.
- Download progress reaches every caller sharing one GET, not only the first.
  A caller that joins mid-body hears the last value at once, and every
  transfer reports `0` when its response starts. Cache hits stay silent.
- `BytesResolver.peek` answers at once whether a request is `cached`,
  `inFlight` or `absent`, from the RAM index and the requests underway.
- `IBytesStore`: the store interface behind the ladder (`contains`, and the
  handles below). `BytesCache.open` returns one; `IBytesIndex` gains a sync
  `peek`. `HttpBytesClient.isInFlight` reports a running GET.
- `IBytesStore.leaseFile` hands out a `FileLease`: the path of a stored
  payload that eviction, expiry and orphan reclaim leave in place until the
  lease is released. VM stores only; memory and web stores return null.
- Named quotas (`BytesQuota`: images, video ranges, Lottie frames, glyphs)
  share one store budget: a full quota evicts only within itself, and under
  total pressure the quota furthest over its share gives back first. Writes
  and `BytesRequest` take a `quota`; the index keeps it per row.
- `IBytesStore.registerQuota` counts files another owner keeps (a frame
  cache, glyph pages) against the store budget. The owner reports its usage
  and frees bytes when asked through its callback; the store never touches
  those files.
- **Behaviour change:** retention age counts from last use, not from the
  write, so a body used daily never expires. `BytesRetention.standard` is now
  30 days since last use, 10 000 entries and 1 GiB.
- One eviction pass plans from a single index listing (was one listing per
  victim).
- Request priorities: `RequestPriority` (visible > preload > background) on a
  `PriorityToken` the caller may change while the GET is queued.
  `BytesRequest.priority`, `send` / `getBytes(priority:)`. The six-slot queue
  serves by priority, then arrival; a coalesced GET takes its callers' highest
  priority, and a GET whose last caller cancels leaves the queue at once. The
  `pool` dependency is gone.
- `RevalidationPolicy` per request: `http` (the default, unchanged),
  `staleWhileRevalidate` (serve a stale hit at once and refresh it in the
  background through ETag / Last-Modified; a 304 refreshes the meta, a 200
  replaces the bytes) and `immutable` (never revalidate; for media).
- `IBytesStore.alias(local, server)` makes a server key resolve to a locally
  produced payload with no copy or move; `release(local)` drops the local key
  while aliased keys keep the bytes. A payload read by several keys counts
  once against the budget and goes with its last reader. The index keeps the
  shared payload key per row.
- **Breaking for implementers:** `IBytesCache.write` takes a `quota`, and
  `IBytesIndex` needs a sync `peek`. Callers are unaffected.
- `HttpBytesClient.stream` returns a response whose body is still
  streaming, and takes a single `ByteRange`. `206` answers expose
  `contentRange` and `totalLength`; a `416` fails as
  `range_not_satisfiable`. Streamed GETs are never coalesced and hold a slot
  until their body ends. The conditional middleware sends `If-Range` (strong
  ETag only) on range GETs.
- Ranged resources: `IRangedBytesStore` keeps a sparse payload per key with
  its ranges, length and validator, in the same index and quotas (counted
  against `video_ranges`, evicted whole, never while leased). Another
  validator drops every span. The VM store supports it; web stores report
  `supportsRanges == false`.
- `RangedBytes` / `RangedResource` fetch missing ranges in chunked range GETs
  (one shared resource per key) and announce each write (`RangeLanded`). A
  `200` to a range GET drops the spans and keeps the new body; a server
  without `Accept-Ranges` is read sequentially.
- `RangedResource.fastStart` fetches the head of a progressive MP4, finds
  `moov` and fetches the tail when `moov` follows the media data, so playback
  starts before the file is cached. Every open of a key shares one resource.
- Native reader (`package:http_bytes_cache/native_reader.dart`, VM): a C
  library the package's build hook compiles. `NativeRangedReaders` publishes
  ranged resources so native players read the sparse files directly by cache
  key and block only on missing bytes, which Dart fetches at the reader's
  priority and signals over FFI once landed. Players reach the C functions
  through `NativeRangedReaders.apiAddress`. No Windows build yet.
- `package:http_bytes_cache/testing.dart`: `runBytesStoreContract`,
  `runRangedBytesStoreContract` and in-memory index and blob fakes.

## 0.1.0

- Initial release as `http_bytes_cache`: the image_bytes_cache 0.4.1 engine
  moved into mpx under a kind-neutral name. Behaviour is unchanged.
- Types lose their `Image` prefix: `ImageBytes*` becomes `Bytes*` (for example
  `BytesCache`, `BytesResolver`, `BytesRequest`, `IBytesCache`,
  `MemoryBytesCache`), `ImageCacheKey` becomes `BytesCacheKey`, and
  `ImageHttpCache*` becomes `HttpCache*`. The library is
  `package:http_bytes_cache/http_bytes_cache.dart`.
- Stores written by image_bytes_cache open unchanged: on-disk and web storage
  names keep their old spelling.
