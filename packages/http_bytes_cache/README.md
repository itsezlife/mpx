# http_bytes_cache

A durable cache for HTTP response bytes, in pure Dart. It resolves a URL to its
bytes through a short ladder (fresh cache hit, conditional or full GET with
in-flight coalescing, write-through) and keeps them on disk (VM) or in the
Cache API and OPFS (web).

## Install

Not published yet. Depend on it from git:

```yaml
dependencies:
  http_bytes_cache:
    git:
      url: https://github.com/itsezlife/mpx.git
      path: packages/http_bytes_cache
```

## Usage

```dart
import 'package:http_bytes_cache/http_bytes_cache.dart';

Future<void> main() async {
  // Once at start-up. On the VM pass a cache directory; web ignores it.
  await BytesCache.configure(
    await BytesCache.open(directory: '/path/to/cache/http_bytes'),
  );

  final bytes = await BytesResolver.shared().resolve(
    const BytesRequest(url: 'https://cdn.example.com/file.bin'),
  );
  print(bytes.length);
}
```

## Features

- Resolve ladder with HTTP validation: fresh hits skip the network, stale hits
  revalidate with ETag / Last-Modified, and a network error can serve held
  bytes.
- In-flight coalescing: concurrent requests for one resource share one GET;
  each caller can cancel on its own, and every caller hears its progress.
- Request priorities (visible, preload, background) that can change while a
  request waits for one of the six slots.
- Per-request revalidation: follow HTTP freshness, stale-while-revalidate, or
  immutable.
- A synchronous peek: cached, in flight, or absent.
- Streaming bodies and single-range GETs (`206`, `Content-Range`, `If-Range`).
- Middleware chains for HTTP (timeout, retry, bearer, conditional, logger) and
  for the cache (skip-cache, logger).
- Stable identity from the canonical URL and headers, or a host-supplied cache
  key.
- One store budget shared by named quotas (images, video ranges, Lottie
  frames, glyphs), including quotas over folders other owners keep. Age counts
  from last use; no background timer.
- Leased file paths that eviction leaves alone, and aliases that let a local
  file answer for its server key without a copy.
- VM and web stores; open falls back to memory on a hard storage failure.
- Soft diagnostics: silent, `developer.log`, or a host callback.

## Docs

- [Architecture](docs/architecture.md), [resolve ladder](docs/resolve-ladder.md),
  [storage](docs/storage.md), [development](docs/development.md)
- [Glossary](CONTEXT.md)
- [ADR 0002: the bytes cache](../../docs/adr/0002-bytes-cache.md)
