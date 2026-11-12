# Changelog

## Unreleased

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
