# ADR 0002: The bytes cache

`http_bytes_cache` is image_bytes_cache renamed and extended. It keeps two kinds
of resource on one disk store: whole resources (the existing resolve ladder)
and ranged resources (a sparse file per resource with a range index), which it
owns end to end, including a native reader that players open by key. One
index, one eviction by last use, named quotas, some of them over folders other
packages own. Requests carry a priority; stale-while-revalidate is a
per-request policy. The HTTP middleware chain is shared and gains streaming
bodies and range requests. The composition root `mpx` fits it under the
core's fetch seam.

**Status**: Accepted (decided with the maintainer 2026-11-10)
**Relates to**: 0001, 0003, 0004, 0005, 0007

## Context

image_bytes_cache is a pure-Dart whole-body engine: URL + headers identity or
a host `cacheKey`, a RAM index mirror over VM isolate files or web Cache API +
OPFS blobs, a resolve ladder (fresh, conditional GET, unconditional, stale only
on network error), an HTTP client with timeout, retry, bearer and conditional
middlewares, a FIFO pool of 6, and in-flight coalescing where the last caller's
cancel aborts the socket.

It fits under the core inside the host's `ContentFetcher`, but it misses what
the core's fetch contract asks for, and it has nothing for video: no ranges, no
resume, the whole body buffered by design.

## Decision

### Shape

| Area | Decision |
| --- | --- |
| Name | `http_bytes_cache`, without the `mpx_` prefix; `Image*` types renamed to kind-neutral names |
| Identity | Host-supplied cache key (`MediaKey`-derived), mandatory for media; URL identity stays for plain web images |
| Aliases | `alias(local, server)` makes the server key resolve to a local resource's bytes, no copy or move; `release(local)` drops the local key, otherwise retention does (ADR 0007) |
| Resource kinds | Whole (one blob, resolve ladder) and ranged (sparse file, range set) |
| Store | One disk store, one index, one eviction by last use |
| Quotas | Named quotas: images, video ranges, Lottie frames, glyphs. A long video cannot evict every avatar |
| Registered quotas | Lottie frame caches and glyph pages keep their own files, formats and offset reads. Their folders register as named quotas: the store accounts total bytes and decides which quota gives back space; the owner evicts when asked, through a callback per quota. The store never touches files it does not own |
| Priorities | Every request carries visible > preload > background; the priority can change while queued or in flight. The 6-slot queue serves by priority, then arrival |
| Stale-while-revalidate | A per-request policy serves stale bytes at once and revalidates in the background through ETag / Last-Modified. Media defaults to no revalidation (immutable); avatars and similar opt in |
| Fit under the core | A fetch adapter in `mpx`, the composition root over the core and the cache, fills `ContentFetcher`: key to cache key, `CancellationToken` to the cache's cancel token, typed errors to transient / permanent, byte progress to `onProgress`. The core and the cache do not depend on each other |

### Gaps to close before it serves the core

| Gap | Required behaviour |
| --- | --- |
| Progress | Flight-level fan-out: every sharer hears progress, a late joiner first gets the last value, a 0 report at transfer start, none for a cache hit |
| Sync peek | `needsDownload` answers at once from the RAM index plus the in-flight set |
| File handout | A path API with a lease; eviction and sweep spare a leased file |
| Last-use expiry | TTL counts from last use, not write time |
| One store | The cache owns the media folder and accounts the registered ones; host sweeps over tier folders go away, so orphan reclaim and an mtime sweep no longer fight |

### Ranged resources

| Area | Decision |
| --- | --- |
| Row | Key, total length, strong validator (ETag, or a strong Last-Modified), range set of present bytes, last use |
| Payload | One sparse file per resource. Blob port gains write-at-offset, ranged read, ranges query |
| Eviction | Whole resources by last use within their quota; never a resource with an open reader |
| Requests | Single range only. `If-Range` with a strong ETag. A `200` answer to a ranged request drops every span and keeps the new body. No `Accept-Ranges`: sequential full download |
| Ownership | The cache owns range requests, writes into the sparse file and range index, and the "range landed" signal |
| Reads | A native reader by key, part of this package: it reads the sparse file directly and blocks on a missing range; the missing range asks Dart to fetch it at a priority, and Dart signals over FFI once it is written. `mpx_player` opens it inside its `DataSource` and resource loader; any other player may |
| Native names | `http_bytes_cache_*`, short `hbc_*` allowed for C symbols |
| Fast start | Prefetch the head, find `moov`, fetch the tail when `moov` is at the end. One shared reader per resource |
| HLS | Playlists and segments are ordinary resources. VOD playlists are immutable; live ones revalidate with `If-None-Match` |

### HTTP middlewares

| Middleware | Change |
| --- | --- |
| Response | A streaming body variant that middlewares pass through |
| Context | `Range` and `If-Range` slots; `206` and `Content-Range` parsing |
| Conditional | `If-Range` on range GETs, `If-None-Match` / `If-Modified-Since` on full GETs |
| Timeout, retry, bearer, logger | Unchanged; apply to range GETs |

## Why

- Every reference client keeps streamed video in the same store as other media,
  keyed by content identity, read by a thin blocking adapter. None uses the
  platform media cache.
- Dart keeps fetch, validation and budgets, so ETag rules and middlewares are
  written once. Media3's `CacheDataSource` does no validation at all.
- Bytes go network to file to player; only control messages cross into Dart,
  so the hot path never round-trips per chunk.
- Last-use expiry matches the core's "one media disk store kept by last use":
  a GIF used daily must not expire after two weeks.
- Owning the native reader keeps the range protocol in one package, so the
  cache stays usable by other players and the player needs no host wiring.
- Registered quotas give one disk budget without putting frame or glyph
  formats into an HTTP cache, and nothing deletes another package's files.
- Aliases let a sender's local file become the server's resource with no copy
  and no key change in the surface already playing it.
- Priorities matter once ranged reads and feed preloads share six slots; a
  cell becoming visible must overtake background work.

## Rejected

| Alternative | Why not |
| --- | --- |
| Media3 `SimpleCache` / Apple native caches | Two network stacks, no validation on Android, a folder that deletes foreign files, no shared budget |
| Loopback HTTP proxy for everything | Every byte crosses a socket and the Dart isolate; iOS suspends sockets in background; port and entitlement exposure |
| A separate range cache package | Two evictions over one disk |
| Moving Lottie frames and glyph pages into the cache's blobs | Format knowledge in the HTTP cache; their offset reads lose their files |
| Re-keying a local resource on upload (move or copy) | A key change under a playing surface, or doubled bytes |
| The fetch adapter inside this package | A core dependency in a cache that should stand alone |
| Replacing the core's `ContentFetcher` seam with the cache | The seam stays the host's; the cache is one way to fill it |
| `AVAssetDownloadURLSession` | System-owned store outside our budget; offline downloads are out of v1 |

## Consequences

- The host's media disk store and its tier folders (example `MediaDiskCache`,
  `ByteCache`) are replaced by the cache's store.
- The chat's Giphy disk-then-download path becomes one resolve call through
  the adapter.
- The player's native side depends on this package's native reader, not on
  Dart per read (ADR 0004); the package gains a native part beside its pure
  Dart core.
- This replaces the chat's ADR 022 rule that the Lottie frame and glyph tiers
  keep no budget of their own: they now count against named quotas.
- `mpx_lottie`'s frame cache and the chat's glyph atlas each implement
  an eviction callback.

## Open in implementation

- `stale-if-error` parsing and whether SWR also reads `Cache-Control`
  directives or only the per-request policy.
- Duplicate write-through per coalesced caller, the O(n² log n) capacity trim,
  meta-only update on 304: fixes not scheduled.
- Process-wide singletons (`shared`, diagnostics): whether to move to instance
  scope.
- Provenance refresh: a hook between 403/410 and re-resolving an expired URL.
- One index file or two indexes under one retention brain for whole and ranged
  rows.
- Quota sizes and the default last-use horizon (the chat's ADR 022 uses one
  month).
- How the native reader ships (hook-built C library or plugin code) and how
  Kotlin and Swift link it; whether it joins the prebuilt pipeline (ADR 0008).
- Alias edge cases: a server key that already has bytes, chains, and release
  while a reader is open.
- Encrypted-at-rest media: out unless DRM lands.

## Provenance

Planning tickets `01`, `03`, `08`, `14` (name addendum), `17` (native
reader), `18` (adapter home), `19` (registered quotas), `23` (alias), `24`
(native names), `25` (priorities, SWR), `27` (adapter folded into `mpx`); research `01-bytes-tier-fit`
(file:line on both sides), `03-streaming-cache.md` (Media3, Apple loader, RFC
9110 / 8216, the three references' range stores). chat_scroll_view ADR 022
amendments *one media disk store* and *download progress*.

## Related

ADR 0003 (fetch seam), 0004 (player reads), 0007 (capture output lands here).
