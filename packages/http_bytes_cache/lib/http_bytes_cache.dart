/// Durable bytes of HTTP resources, whatever their format.
///
/// Product: raw bytes with an identity key, never decoded media. After open,
/// meta lives in a RAM mirror; durable meta commits once per exclusive mutate
/// epoch; payloads sit on platform blob stores.
/// Concurrent cache reads are allowed when no mutate holds the gate. Hosts
/// resolve via [BytesResolver] (cache → network coalesce → write-through).
///
/// Wire shared instances with [BytesCache.configure] /
/// [BytesCache.open] and optionally [HttpBytesClient.configure] for a
/// process-wide HTTP client. Soft storage failures report through
/// [BytesDiagnostics]. Open degrades to an in-memory store on hard
/// failure unless [BytesCache.open] is called with
/// `throwOnOpenFailure: true`. Hosts bridge diagnostics; this package does
/// not depend on a product logger.
library;

export 'package:cancel_token/cancel_token.dart'
    show CancelToken, CancelledException;

export 'src/bytes_cache.dart';
export 'src/bytes_diagnostics.dart';
export 'src/bytes_resolver.dart';
export 'src/cache/cache_middleware.dart';
export 'src/cache/middlewares/logger_middleware.dart';
export 'src/cache/middlewares/skip_cache_middleware.dart';
export 'src/http/byte_range.dart';
export 'src/http/http_bytes_client.dart';
export 'src/http/http_bytes_transfer.dart';
export 'src/http/middlewares/bearer_middleware.dart';
export 'src/http/middlewares/conditional_middleware.dart';
export 'src/http/middlewares/logger_middleware.dart';
export 'src/http/middlewares/retry_middleware.dart';
export 'src/http/middlewares/timeout_middleware.dart';
export 'src/http/request_priority.dart';
export 'src/http/retry_backoff.dart';
export 'src/http_cache_freshness.dart';
export 'src/ranged/byte_range_set.dart';
export 'src/ranged/ranged_bytes.dart';
export 'src/util/byte_count_format.dart';
