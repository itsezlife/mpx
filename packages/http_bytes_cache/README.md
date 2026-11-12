# http_bytes_cache

A durable cache for HTTP response bytes, with an HTTP client, middlewares and a disk store, in pure Dart.

> Skeleton: the API lands with the tickets of the mpx build order. Nothing is
> usable yet.

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
```

## Features (planned)

- Whole resources with HTTP validation
- Ranged resources for streamed media
- One disk store with named quotas

## Docs

- [Spec](../../docs/spec.md)
- [Package topology (ADR 0001)](../../docs/adr/0001-package-topology.md)
- [ADR 0002](../../docs/adr/0002-bytes-cache.md)
