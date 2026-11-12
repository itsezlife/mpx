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
- `package:http_bytes_cache/testing.dart`: `runBytesStoreContract` and
  in-memory index and blob fakes.

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
