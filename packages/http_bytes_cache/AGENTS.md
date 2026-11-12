# AGENTS.md

Orientation for agents working in **`http_bytes_cache`**, the pure-Dart bytes
cache of mpx (`packages/http_bytes_cache/`). The repo-level
[`AGENTS.md`](../../AGENTS.md) and [ADR 0002](../../docs/adr/0002-bytes-cache.md)
come first; this file adds the package's own rules. Deep detail lives in
[`docs/`](docs/). Glossary: [`CONTEXT.md`](CONTEXT.md).

`http_bytes_cache` is a durable remote **bytes** engine: identity key → RAM
meta mirror → platform blob stores, plus a resolve ladder (cache → network
coalesce → write-through).

## Commands (run before you claim done)

```shell
# Tests — test/unit_test.dart is the single aggregate entrypoint for VM suites.
dart test test/unit_test.dart
dart analyze --fatal-infos
dart format --line-length 80 lib test

# Web smoke (Chrome) — CI merge gate; run locally when touching web blob / open:
dart test -p chrome test/open/open_web_test.dart

# Store + ladder microbenches (not a CI gate) — baseline deltas:
dart test benchmark/compare_test.dart --dart-define=SAVE_BASELINE=true
dart test benchmark/compare_test.dart
# Optional RSS fill/prune lane (noisy; one-machine deltas only):
# dart test benchmark/compare_test.dart --dart-define=MEMORY_LANE=true
```

More: [`docs/development.md`](docs/development.md).

## Module map (`lib/src/`)

| Path | What | Doc |
| --- | --- | --- |
| `bytes_cache.dart` | `BytesCacheKey`, retention, quotas, ports, `IBytesStore`, `FileLease`, `RegisteredQuota`, `IndexedBytesCache`, Memory/NoOp, `HttpCacheMeta` / rich hit, `BytesCache` open/configure | [architecture](docs/architecture.md), [storage](docs/storage.md) |
| `cache/cache_middleware.dart` | Sealed `CacheOperation` / result, `CacheMiddleware` fold, `MiddlewareBytesCache`, rich `CacheReadHit` | [resolve-ladder](docs/resolve-ladder.md) |
| `cache/middlewares/` | Opt-in Skip-cache + Cache `Logger$Developer` | [resolve-ladder](docs/resolve-ladder.md) |
| `bytes_resolver.dart` | Ladder: freshness → conditional/unconditional GET → write-through | [resolve-ladder](docs/resolve-ladder.md) |
| `http_cache_freshness.dart` | Freshness policy + response-meta helpers | [resolve-ladder](docs/resolve-ladder.md) |
| `http/http_bytes_client.dart` | HTTP GET types, middleware chain, client, priority slot queue, progress fan-out | [resolve-ladder](docs/resolve-ladder.md) |
| `http/request_priority.dart` | `RequestPriority`, `PriorityToken` | [resolve-ladder](docs/resolve-ladder.md) |
| `testing/` (via `lib/testing.dart`) | `runBytesStoreContract`, in-memory index / blob fakes | [development](docs/development.md) |
| `http/middlewares/` | HTTP middlewares (`Timeout`, opt-in `Retry`, `Bearer`, `Conditional`, `Logger$Developer`) | [resolve-ladder](docs/resolve-ladder.md) |
| `bytes_diagnostics.dart` | Soft-path policy (`silent` / `developer` / `onEvent`); ops include revalidated / stale-used / unconditional | [resolve-ladder](docs/resolve-ladder.md) |
| `bytes_index_document.dart` | Versioned index JSON codec (`v:1`, additive HTTP `h` meta) | [storage](docs/storage.md) |
| `bytes_web_keys.dart` | Synthetic `.invalid` Cache URLs + OPFS dir names | [storage](docs/storage.md) |
| `isolate_controller.dart` | Long-lived isolate spawn/add/stream/close (VM blob IO) | [storage](docs/storage.md) |
| `environment_specific/cache_open*.dart` | Conditional `open` (VM files / web Cache+OPFS) | [storage](docs/storage.md) |
| `environment_specific/*_vm.dart` | File index + isolate blob worker | [storage](docs/storage.md) |
| `environment_specific/*_js.dart` | Cache API index; Cache/OPFS blobs by 64 KiB cut | [storage](docs/storage.md) |

Public API is the barrel `lib/http_bytes_cache.dart`. See
[`docs/architecture.md`](docs/architecture.md).

## Hard rules (do not violate)

1. **Storage grows here**, not in host UI util trees. Widgets depend on
   `IBytesResolver` / `IBytesCache` only.
2. **No Hive** on this path. No payload bodies in SQLite BLOB columns. No live
   SQL `SELECT` on the resolve hot path.
3. **RAM meta after open.** Pure `read` must not durable-commit and must not
   serialize against other pure reads. Mutate epochs call `IBytesIndex.commit`
   **once**.
4. **Orphan reclaim only under the exclusive mutate gate** (wired into
   `IndexedBytesCache`). Wrappers must not reclaim outside it.
5. **Conditional imports** via `dart.library.js_interop` for web vs VM. Do not
   select this package’s platform stubs with `dart.library.html`.
6. **Index wire format** only through `BytesIndexDocumentCodec`. Wipe on
   unsupported version / corrupt decode (remote bytes are disposable).
7. **One VM test entrypoint:** a new `test/**/foo_test.dart` (except Chrome-only
   open) must be wired into `test/unit_test.dart` (import + `main()` inside
   `group('Unit', …)`) or the default suite run skips it.
8. **Pure Dart core:** no Flutter SDK / `flutter_test`, no `package:shared`,
   no `lints_tool`. No `package:flutter` or `package:shared` imports in
   `lib/`, and no dependency on `mpx_core` (ADR 0001). Paint widgets and
   Flutter adapters do not belong here. Store / ladder microbenches stay in
   this package; head-to-head compare and scroll-profile harnesses never do.
   Competitor deps must not land on this pubspec.
9. **Storage names are frozen.** VM index file, web Cache names, OPFS
   directory and the synthetic `image-bytes.invalid` host keep their
   pre-rename spelling; changing them orphans stores already on disk.

## Load-bearing invariants (don't break silently)

- **Hot path:** concurrent shared reads on the RAM index mirror + blob read;
  soft LRU in `_pendingAccess` only; no durable meta IO on paint hits.
- **Mutate epoch:** write / evict / prune / TTL-delete / reclaim / close share
  one exclusive domain; snapshot RAM → flush soft access → mutate RAM + blobs →
  one `commit` → reclaim when applicable. Thrown commit restores the RAM
  snapshot (no optimistic durable hit) and rethrows.
- **64 KiB cut:** VM transferable isolate writes and web OPFS vs Cache API use
  the same threshold. Do not collapse to all-OPFS or all-Cache without updating
  docs and tests. Web hot reads with known index `byteLength` ≥ cut go OPFS-first
  (skip Cache miss tax); twin-clear-before-write stays.
- **Empty cached payload = miss** in the resolver; empty durable writes are
  not retained (evict); sticky empty rows scrub on read; write-through failure
  never fails a successful network resolve (diagnostics only; throwing
  `onEvent` is swallowed). Stale-on-network-error returns non-empty cached
  bytes on `$Network` / `$Timeout` / exhausted `$Server` only — never on
  `$Cancelled` / `$Authentication` / definitive `$Request` or empty/missing
  cache.
- **Open:** hard storage failure degrades to `MemoryBytesCache` unless
  `throwOnOpenFailure`; partial VM worker / web handles are closed before
  degrade or rethrow. Missing VM `directory` still throws. `configure`
  closes the previous shared instance before assign. `BytesResolver.shared`
  re-reads process-wide cache/client on each resolve (no one-shot snapshot).
  `resetShared` also clears resolver and client shared wiring.
- **Retention:** age from last use, checked on read; capacity on write/prune
  in one eviction pass across quotas; no background timer. `standard` = 30
  days / 10 000 entries / 1 GiB, shared by `BytesQuota.standard`. Non-positive `maxEntries` /
  `maxBytes` assert.

## Gotchas quick-reference

- Header key casing and map order must not change identity or coalesce keys
  (`BytesCacheKey.canonicalHeaders`). Conditional request headers
  (`If-None-Match` / `If-Modified-Since` / equivalents) are excluded from
  identity; `Authorization` and other representation headers still participate.
- Coalesce and durable identity use `BytesCacheKey` (length-prefixed fingerprint
  material; no `url|headers` join). Relative vs absolute `Uri.base` equivalents
  share one key. Explicit `cacheKey` is full identity for durable and coalesce
  (`HttpBytesContext.identityOverride`; headers on wire only). In-flight
  coalesce keys are post-middleware (Bearer `Authorization` participates;
  conditionals do not) unless identity override is set. Opt-in
  [HttpBytesConditionalMiddleware] seeds `If-None-Match` / `If-Modified-Since`
  from `HttpBytesContext.etag` / `lastModified`. Place after Bearer, before
  coalesce. `BytesRequest.skipCache` sets cache Skip-cache via
  `CacheContext` when the store is a middleware wrapper.
- Distinct URLs that share a basename must not collide on disk (fingerprint).
- VM store under app **cache** root, not documents. Web ignores `directory`.
- `MemoryBytesCache` / `NoOpBytesCache` stay usable after `close`;
  Indexed and durable wrappers throw after close.
- Web payload Cache keys are synthetic `https://image-bytes.invalid/...`, not
  the real fetch URL.
- `HttpBytesClient` Timeout middleware (connect + receive) does not cover pool
  wait time (intentionally unbounded queue). AbortableRequest uses a shared
  **flight** `CancelToken.whenCancel` after a slot is acquired; per-caller tokens
  cancel only that subscriber until the last one aborts the flight. Per-send
  overrides live on typed `HttpBytesContext` (sealed `$` exceptions for hosts).
  Default success is 2xx or 304; empty-body-as-`$Internal` does not apply to 304
  (illegal 304 bodies are ignored).
- Chrome open test is the honesty check for Cache/OPFS and a CI merge gate; do
  not merge web blob changes on green VM tests alone.

## The docs

- [`docs/architecture.md`](docs/architecture.md): layers, data flow, public API, engine vs consumers.
- [`docs/storage.md`](docs/storage.md): brain concurrency, retention, VM/web backends, index wipe.
- [`docs/resolve-ladder.md`](docs/resolve-ladder.md): key, resolver, client, diagnostics, open/configure.
- [`docs/development.md`](docs/development.md): commands, seams, layout, store + ladder microbenches.
- [`CONTEXT.md`](CONTEXT.md): ubiquitous language glossary.
- [`CHANGELOG.md`](CHANGELOG.md): version history (`version:` in pubspec must match a `##` heading).
- [`benchmark/`](benchmark/): package-local store + ladder compare harness (`compare.dart`).
