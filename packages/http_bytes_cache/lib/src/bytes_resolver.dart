import 'dart:async';
import 'dart:typed_data';

import 'package:cancel_token/cancel_token.dart';
import 'package:http/http.dart' as http;
import 'package:http_bytes_cache/src/bytes_cache.dart';
import 'package:http_bytes_cache/src/bytes_diagnostics.dart';
import 'package:http_bytes_cache/src/cache/cache_middleware.dart';
import 'package:http_bytes_cache/src/cache/middlewares/skip_cache_middleware.dart';
import 'package:http_bytes_cache/src/http/http_bytes_client.dart';
import 'package:http_bytes_cache/src/http/middlewares/conditional_middleware.dart';
import 'package:http_bytes_cache/src/http_cache_freshness.dart';
import 'package:meta/meta.dart';

/// Paint-relevant provenance of a resolved body.
///
/// Binary on purpose: hosts need "downloaded body or not," not every ladder
/// diagnostic. [cache] means the body was served without downloading a new
/// network body (fresh store hit, 304 reuse, or stale-served on soft network
/// failure). [network] means a downloaded response body, including an
/// unconditional full GET that replaces stale bytes.
enum BytesOrigin {
  /// Body served without a network download of a new representation.
  cache,

  /// Body taken from a downloaded HTTP response.
  network,
}

/// Full body bytes plus [BytesOrigin].
///
/// Returned by [IBytesResolver.resolveRich]. Bytes-only
/// [IBytesResolver.resolve] remains and returns the same body bytes for
/// the same request. Not a streaming surface — one completed body.
@immutable
final class BytesResolveResult {
  /// [bytes] is the full resolved body; [origin] is paint-facing provenance.
  const BytesResolveResult({
    required this.bytes,
    required this.origin,
  });

  /// Full body. Same bytes [IBytesResolver.resolve] would return.
  final Uint8List bytes;

  /// Whether those bytes came from the store without a download, or from the
  /// network.
  final BytesOrigin origin;
}

/// Arguments for [IBytesResolver.resolve] / [IBytesResolver.resolveRich].
@immutable
final class BytesRequest {
  const BytesRequest({
    required this.url,
    this.headers,
    this.cacheKey,
    this.skipCache = false,
    this.onBytesProgress,
    this.cancelToken,
  });

  /// Absolute or [Uri.base]-relative URL.
  ///
  /// The ladder resolves this with [Uri.base.resolve] for both the network GET
  /// and the default [BytesCacheKey] (when [cacheKey] is null), so relative and
  /// absolute forms of the same resource share one durable identity.
  final String url;

  /// Sent on the network hop.
  ///
  /// When [cacheKey] is null, folded into the default [BytesCacheKey] via
  /// [BytesCacheKey.fromUrl]. When [cacheKey] is set, still sent on the wire
  /// but not folded into identity. See [cacheKey].
  final Map<String, String>? headers;

  /// When set, the entire durable and coalesce identity for this resolve.
  ///
  /// Null builds identity with [BytesCacheKey.fromUrl] from the canonical URL
  /// and [headers]. Non-null: [headers] still go on the GET, but they do not
  /// change the key. The ladder copies this into
  /// [HttpBytesContext.identityOverride] so in-flight coalesce matches the
  /// durable slot.
  ///
  /// If you vary `Authorization` (or other representation headers) across
  /// users, omit this field so headers participate, or mint a distinct key per
  /// tenant. One shared override across tenants shares one cache slot. When
  /// this field is set and request headers include `Authorization`, the ladder
  /// reports [BytesLogOp.cacheKeyAuthorization] at debug level (silent
  /// by default). Bearer-injected tokens are not checked here.
  final BytesCacheKey? cacheKey;

  /// When true, durable read misses and write is a no-op for this resolve.
  ///
  /// HTTP still runs. Requires a [MiddlewareBytesCache] whose chain
  /// includes [SkipCacheMiddleware] (or middleware that honors
  /// [CacheContext.skipCache]). Plain [IBytesCache] stores ignore the
  /// flag. Not part of [BytesCacheKey] identity.
  final bool skipCache;

  /// Optional sink for honest HTTP body progress on a network fetch.
  ///
  /// Forwarded to [HttpBytesClient.send] only when the ladder actually
  /// fetches. A durable non-empty fresh cache hit returns bytes without
  /// invoking this callback. A transfer reports `0` when its response starts,
  /// then cumulative bytes per chunk. Every caller sharing one coalesced GET
  /// hears it; a caller that joins mid-body first hears the last value. Resolve remains a single completed body ([resolve] or
  /// [resolveRich]); this is not a streaming resolve API. Does not participate
  /// in [BytesCacheKey] identity or in-flight coalesce.
  final BytesProgressCallback? onBytesProgress;

  /// Cancels this caller's network fetch.
  ///
  /// Forwarded to [HttpBytesClient.send] as the per-caller token: cancelling
  /// fails this resolve with [HttpBytesException$Cancelled] and never serves
  /// stale bytes. A coalesced GET keeps running while another caller still
  /// waits on it; cancelling its last caller aborts the request. A durable
  /// fresh hit returns without consulting the token. Does not participate in
  /// [BytesCacheKey] identity or in-flight coalesce.
  final CancelToken? cancelToken;
}

/// Looks up bytes in a cache, then fetches, then write-through.
abstract interface class IBytesResolver {
  /// Resolves [request] to bytes.
  ///
  /// Same ladder and failure rules as [resolveRich]; returns only the body.
  /// Prefer [resolveRich] when paint policy needs [BytesOrigin].
  ///
  /// Empty cached payloads count as a miss so a bad empty write cannot poison
  /// the ladder. Fresh hits return without a network hop. Stale hits with
  /// validators issue a conditional GET when the client stack includes
  /// [HttpBytesConditionalMiddleware]; 304 reuses cached bytes and refreshes
  /// meta. After a network hit, persistence runs off the critical path; a
  /// durable write failure is reported via [BytesDiagnostics] and does
  /// not fail this future.
  ///
  /// Flaky or offline GET: if this resolve already loaded non-empty cached
  /// bytes for the key and the send fails with
  /// [HttpBytesException$Network], [HttpBytesException$Timeout], or
  /// [HttpBytesException$Server], the future completes with those bytes.
  /// When Retry is on the client, it has already finished by the time
  /// `$Server` reaches the ladder. Audible diagnostics get
  /// [BytesLogOp.resolveStaleUsed].
  ///
  /// Cancel, 401/403, and client errors such as 404 still fail the future.
  /// Empty or missing cache entries do too. There is no host `allowStale`
  /// switch; this is the engine default.
  ///
  /// Uses [HttpBytesClient.send] with [HttpBytesRequest]. Typed
  /// [HttpBytesException] failures propagate when stale cannot be served.
  /// When [BytesRequest.onBytesProgress] is set, the ladder forwards it
  /// on a network fetch only. Fresh cache hits do not synthesize progress
  /// events.
  Future<Uint8List> resolve(BytesRequest request);

  /// Resolves [request] to bytes plus [BytesOrigin].
  ///
  /// Origin mapping: fresh store hit, 304 reuse, and stale-served soft failure
  /// → [BytesOrigin.cache]; downloaded response body (including full GET
  /// after stale) → [BytesOrigin.network]. Ladder `resolve_*` diagnostics
  /// stay the detailed channel; this is paint-facing only.
  ///
  /// Honors the same [BytesRequest] fields as [resolve] (`skipCache`,
  /// progress callback, [BytesRequest.cacheKey] override rules). Body
  /// bytes match [resolve] for the same request.
  Future<BytesResolveResult> resolveRich(BytesRequest request);
}

/// Default ladder: [IBytesCache] then [HttpBytesClient].
///
/// ## Resolve order
///
/// 1. Rich cache read (skip context when [BytesRequest.skipCache] is set
///    on a [MiddlewareBytesCache]). Empty bytes count as a miss.
/// 2. Fresh hit: return bytes with [BytesOrigin.cache]. No network. No
///    progress events.
/// 3. Stale hit with validators: conditional GET (seeds
///    [HttpBytesContext.etag] / [HttpBytesContext.lastModified]).
/// 4. Stale without validators, or miss: unconditional GET.
/// 5. 304: return cached bytes with [BytesOrigin.cache]; soft meta
///    refresh; emit [BytesLogOp.resolveRevalidated] at debug when
///    diagnostics are audible.
/// 6. 200: return new bytes with [BytesOrigin.network]; soft write-through
///    of bytes + response meta.
/// 7. 412 after a conditional: one unconditional GET, then same as 200 / fail.
///    Unconditional GET after held stale bytes (no validators, or 412) emits
///    [BytesLogOp.resolveUnconditional] at debug. Cold misses stay quiet.
/// 8. `$Network` / `$Timeout` / `$Server` after a non-empty cache hit: return
///    those bytes with [BytesOrigin.cache] and emit
///    [BytesLogOp.resolveStaleUsed] when diagnostics are audible. Cancel,
///    auth failures, 404-class `$Request`, and empty or missing cache still
///    throw.
///
/// Freshness is [HttpCacheFreshness], not [BytesRetention].
/// Conditional headers reach the wire only when the client includes
/// [HttpBytesConditionalMiddleware]. Without it, seeded validators are ignored
/// and the GET stays unconditional. Recommended stack (outermost first):
/// Logger, Retry, Timeout, Bearer, Conditional.
///
/// [BytesRequest.cacheKey] sets durable identity and
/// [HttpBytesContext.identityOverride] (coalesce). [BytesRequest.skipCache]
/// seeds [CacheContext.skipCache] on a middleware store. Network goes through
/// [HttpBytesClient.send]. Typed [HttpBytesException] failures propagate unless
/// step 8 applies.
///
/// [resolve] returns body bytes only. [resolveRich] returns the same bytes plus
/// [BytesOrigin]. Ladder diagnostics remain the detailed channel.
///
/// [BytesResolver.shared] does not snapshot the process-wide cache or
/// client. Each [resolve] / [resolveRich] reads [BytesCache.shared] and
/// [HttpBytesClient.shared] (or their `debugShared` overrides) so configure
/// after first paint still enables durable caching, and
/// [BytesCache.resetShared] / configure replacement cannot leave this
/// ladder permanently bound to NoOp or a closed previous store.
final class BytesResolver implements IBytesResolver {
  /// Injected wiring for tests and hosts that own their own ladder instances.
  ///
  /// [clock] defaults to UTC now. Pass a fixed clock when testing freshness.
  BytesResolver({
    required IBytesCache cache,
    required HttpBytesClient client,
    BytesDiagnostics? diagnostics,
    DateTime Function()? clock,
  }) : _cacheOf = (() => cache),
       _clientOf = (() => client),
       _diagnostics = diagnostics,
       _clock = clock ?? _defaultClock;

  /// Process-wide ladder that re-reads shared cache/client on every resolve.
  BytesResolver._liveShared({BytesDiagnostics? diagnostics})
    : _cacheOf = BytesCache.shared,
      _clientOf = HttpBytesClient.shared,
      _diagnostics = diagnostics,
      _clock = _defaultClock;

  /// Process-wide default when nothing is injected.
  ///
  /// Returns one shared instance, but that instance looks up the current
  /// [BytesCache.shared] / [HttpBytesClient.shared] on each [resolve]
  /// rather than capturing them once at first call.
  factory BytesResolver.shared() {
    _$ensureResetSharedCleanup();
    return debugShared ?? (_shared ??= BytesResolver._liveShared());
  }

  static BytesResolver? _shared;

  /// Test override for [BytesResolver.shared]. Set to `null` to clear.
  @visibleForTesting
  static BytesResolver? debugShared;

  /// Clears the memoized [shared] instance and [debugShared].
  ///
  /// Registered via [BytesCache.addAfterResetShared] so test re-bootstrap
  /// cannot keep a stale override without the store facade importing this
  /// library. Live wiring already re-reads the cache; this only drops the
  /// resolver singleton / debug override.
  @internal
  static void resetShared() {
    debugShared = null;
    _shared = null;
  }

  static var _$resetSharedCleanupInstalled = false;

  static void _$ensureResetSharedCleanup() {
    if (_$resetSharedCleanupInstalled) return;
    _$resetSharedCleanupInstalled = true;
    BytesCache.addAfterResetShared(resetShared);
  }

  final IBytesCache Function() _cacheOf;
  final HttpBytesClient Function() _clientOf;
  final BytesDiagnostics? _diagnostics;
  final DateTime Function() _clock;

  BytesDiagnostics get _effectiveDiagnostics =>
      _diagnostics ?? BytesDiagnostics.current;

  @override
  Future<Uint8List> resolve(BytesRequest request) async {
    final result = await resolveRich(request);
    return result.bytes;
  }

  @override
  Future<BytesResolveResult> resolveRich(BytesRequest request) async {
    final key =
        request.cacheKey ??
        BytesCacheKey.fromUrl(request.url, headers: request.headers);
    final cache = _cacheOf();
    final client = _clientOf();
    final now = _clock();

    // Override wins for durable + coalesce while Authorization still rides
    // the wire. Without distinct keys per tenant, hosts can share one slot
    // across users. Silent when diagnostics are silent (default).
    // Only checks Authorization on the request map. Bearer-injected tokens
    // are not visible here.
    if (request.cacheKey case final _?
        when _hasAuthorizationHeader(request.headers)) {
      _effectiveDiagnostics.report(
        BytesLogEvent(
          level: BytesLogLevel.debug,
          message:
              'BytesRequest.cacheKey override coexists with Authorization; '
              'override wins for durable and coalesce identity. Mint distinct '
              'keys per tenant. key=${key.value}',
          op: BytesLogOp.cacheKeyAuthorization,
        ),
      );
    }

    final cacheContext = switch (request.skipCache) {
      true => CacheContext.empty()..skipCache = true,
      false => null,
    };

    final hit = await _readRich(cache, key, cacheContext);
    if (hit case final cached? when cached.bytes.isNotEmpty) {
      final fresh = HttpCacheFreshness.isFresh(
        cached.httpCacheMeta,
        now: now,
        writtenAt: cached.writtenAt,
      );
      if (fresh) {
        return BytesResolveResult(
          bytes: cached.bytes,
          origin: BytesOrigin.cache,
        );
      }

      if (HttpCacheFreshness.hasValidators(cached.httpCacheMeta)) {
        return _revalidate(
          request: request,
          key: key,
          cache: cache,
          client: client,
          cacheContext: cacheContext,
          cached: cached,
          now: now,
        );
      }
      // Stale without validators → unconditional GET below.
    }

    return _fetchAndStore(
      request: request,
      key: key,
      cache: cache,
      client: client,
      cacheContext: cacheContext,
      now: now,
      staleBytes: switch (hit) {
        final cached? when cached.bytes.isNotEmpty => cached.bytes,
        _ => null,
      },
    );
  }

  /// Conditional GET for a stale hit that still has validators.
  ///
  /// Seeds [HttpBytesContext.etag] / [HttpBytesContext.lastModified] for
  /// [HttpBytesConditionalMiddleware]. On 304, returns cached bytes with
  /// [BytesOrigin.cache] and soft meta refresh. On 412, retries once
  /// without validators. On 200, write-through new bytes and meta with
  /// [BytesOrigin.network]. Transient send failures fall through to
  /// [_serveStaleOrRethrow] with [cached] bytes.
  Future<BytesResolveResult> _revalidate({
    required BytesRequest request,
    required BytesCacheKey key,
    required IBytesCache cache,
    required HttpBytesClient client,
    required CacheContext? cacheContext,
    required BytesRichHit cached,
    required DateTime now,
  }) async {
    final httpContext = _seedHttpContext(request);
    final meta = cached.httpCacheMeta;
    if (meta?.etag case final etag? when etag.trim().isNotEmpty) {
      httpContext.etag = etag;
    }
    if (meta?.lastModified case final lm? when lm.trim().isNotEmpty) {
      httpContext.lastModified = lm;
    }

    try {
      final response = await _send(client, request, httpContext);
      if (response.statusCode == 304) {
        final refreshed = HttpCacheFreshness.afterNotModified(
          cached.httpCacheMeta,
          headers: response.headers,
          validatedAt: now,
        );
        unawaited(
          _softWrite(cache, key, cached.bytes, cacheContext, refreshed),
        );
        _effectiveDiagnostics.report(
          BytesLogEvent(
            level: BytesLogLevel.debug,
            message:
                'BytesResolver revalidated ${key.value} (304); reused cached bytes',
            op: BytesLogOp.resolveRevalidated,
          ),
        );
        return BytesResolveResult(
          bytes: cached.bytes,
          origin: BytesOrigin.cache,
        );
      }

      final bytes = await response.toBytes();
      final nextMeta = HttpCacheFreshness.fromResponseHeaders(
        response.headers,
        validatedAt: now,
      );
      unawaited(_softWrite(cache, key, bytes, cacheContext, nextMeta));
      return BytesResolveResult(
        bytes: bytes,
        origin: BytesOrigin.network,
      );
    } on HttpBytesException$Request catch (error) {
      // 412 Precondition Failed: one unconditional GET (still may serve stale).
      if (error.statusCode != 412) rethrow;
      return _fetchAndStore(
        request: request,
        key: key,
        cache: cache,
        client: client,
        cacheContext: cacheContext,
        now: now,
        staleBytes: cached.bytes,
      );
    } on HttpBytesException catch (error, stackTrace) {
      return _serveStaleOrRethrow(
        error: error,
        stackTrace: stackTrace,
        key: key,
        staleBytes: cached.bytes,
      );
    }
  }

  /// Unconditional GET + soft write-through of bytes and response meta.
  ///
  /// Pass non-empty [staleBytes] when the ladder already held a body for this
  /// key so [_serveStaleOrRethrow] can return it on transient failure. Null or
  /// empty means the failure still throws. Non-empty [staleBytes] also emits
  /// [BytesLogOp.resolveUnconditional] at debug (cold misses stay quiet).
  /// A downloaded 200 body is [BytesOrigin.network].
  Future<BytesResolveResult> _fetchAndStore({
    required BytesRequest request,
    required BytesCacheKey key,
    required IBytesCache cache,
    required HttpBytesClient client,
    required CacheContext? cacheContext,
    required DateTime now,
    Uint8List? staleBytes,
  }) async {
    if (staleBytes case final bytes? when bytes.isNotEmpty) {
      _effectiveDiagnostics.report(
        BytesLogEvent(
          level: BytesLogLevel.debug,
          message:
              'BytesResolver unconditional GET for ${key.value} '
              '(held non-empty cached bytes; full fetch)',
          op: BytesLogOp.resolveUnconditional,
        ),
      );
    }

    try {
      final httpContext = _seedHttpContext(request);
      final response = await _send(client, request, httpContext);
      final bytes = await response.toBytes();
      final meta = HttpCacheFreshness.fromResponseHeaders(
        response.headers,
        validatedAt: now,
      );
      unawaited(_softWrite(cache, key, bytes, cacheContext, meta));
      return BytesResolveResult(
        bytes: bytes,
        origin: BytesOrigin.network,
      );
    } on HttpBytesException catch (error, stackTrace) {
      return _serveStaleOrRethrow(
        error: error,
        stackTrace: stackTrace,
        key: key,
        staleBytes: staleBytes,
      );
    }
  }

  /// Returns non-empty [staleBytes] as [BytesOrigin.cache] for
  /// `$Network` / `$Timeout` / `$Server`.
  ///
  /// If Retry is in the stack, it has already finished before `$Server` lands
  /// here. Cancel, auth, `$Request`, `$Internal`, and empty or missing cache
  /// always rethrow. Audible diagnostics get [BytesLogOp.resolveStaleUsed].
  BytesResolveResult _serveStaleOrRethrow({
    required HttpBytesException error,
    required StackTrace stackTrace,
    required BytesCacheKey key,
    required Uint8List? staleBytes,
  }) {
    // Only the three transient classes qualify. Exhaustiveness keeps
    // Cancelled / Authentication / Request / Internal on the failure path.
    final allowStale = switch (error) {
      HttpBytesException$Network() ||
      HttpBytesException$Timeout() ||
      HttpBytesException$Server() => true,
      HttpBytesException$Cancelled() ||
      HttpBytesException$Authentication() ||
      HttpBytesException$Request() ||
      HttpBytesException$Internal() => false,
    };

    if (allowStale) {
      if (staleBytes case final bytes? when bytes.isNotEmpty) {
        _effectiveDiagnostics.report(
          BytesLogEvent(
            level: BytesLogLevel.warning,
            message:
                'BytesResolver serving stale cached bytes for ${key.value} '
                'after ${error.runtimeType}: ${error.message}',
            op: BytesLogOp.resolveStaleUsed,
            stackTrace: stackTrace,
          ),
        );
        return BytesResolveResult(
          bytes: bytes,
          origin: BytesOrigin.cache,
        );
      }
    }
    Error.throwWithStackTrace(error, stackTrace);
  }

  HttpBytesContext _seedHttpContext(BytesRequest request) {
    final httpContext = HttpBytesContext.empty();
    if (request.cacheKey case final override?) {
      httpContext.identityOverride = override;
    }
    return httpContext;
  }

  Future<HttpBytesResponse> _send(
    HttpBytesClient client,
    BytesRequest request,
    HttpBytesContext httpContext,
  ) async {
    final url = Uri.base.resolve(request.url);
    final httpRequest = http.Request('GET', url);
    if (request.headers case final h?) {
      httpRequest.headers.addAll(h);
    }
    return client.send(
      HttpBytesRequest(httpRequest),
      context: httpContext,
      cancelToken: request.cancelToken,
      onBytesProgress: request.onBytesProgress,
    );
  }

  /// Soft write-through. Failures report; they never fail [resolve].
  Future<void> _softWrite(
    IBytesCache cache,
    BytesCacheKey key,
    Uint8List bytes,
    CacheContext? cacheContext,
    HttpCacheMeta? httpCacheMeta,
  ) => _write(cache, key, bytes, cacheContext, httpCacheMeta: httpCacheMeta)
      .catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        _effectiveDiagnostics.report(
          BytesLogEvent(
            level: BytesLogLevel.error,
            message:
                'BytesResolver write-through failed for ${key.value}: $error',
            op: BytesLogOp.writeThrough,
            stackTrace: stackTrace,
          ),
        );
      });

  /// Rich durable read (bytes + HTTP meta). Falls back to bytes-only stores.
  Future<BytesRichHit?> _readRich(
    IBytesCache cache,
    BytesCacheKey key,
    CacheContext? context,
  ) async {
    Future<BytesRichHit?> fromPlain() async {
      if (cache case final IBytesRichCache rich) {
        return rich.readRich(key);
      }
      return switch (await cache.read(key)) {
        final bytes? when bytes.isNotEmpty => BytesRichHit(bytes: bytes),
        _ => null,
      };
    }

    switch (context) {
      case null:
        return fromPlain();
      case final ctx:
        if (cache case final MiddlewareBytesCache mw) {
          final result = await mw.execute(CacheOperation$Read(key), ctx);
          return switch (result) {
            CacheOperationResult$Read(:final hit?) => BytesRichHit(
              bytes: hit.bytes,
              writtenAt: hit.writtenAt,
              accessedAt: hit.accessedAt,
              httpCacheMeta: hit.httpCacheMeta,
            ),
            CacheOperationResult$Read() => null,
            _ => throw StateError(
              'Cache middleware returned ${result.runtimeType} for read; '
              'expected CacheOperationResult.Read',
            ),
          };
        }
        // Plain store: skipCache has no effect without middleware that honors it.
        return fromPlain();
    }
  }

  /// Durable write-through. Same context story as [_readRich].
  Future<void> _write(
    IBytesCache cache,
    BytesCacheKey key,
    Uint8List bytes,
    CacheContext? context, {
    HttpCacheMeta? httpCacheMeta,
  }) async {
    switch (context) {
      case null:
        await cache.write(key, bytes, httpCacheMeta: httpCacheMeta);
      case final ctx:
        if (cache case final MiddlewareBytesCache mw) {
          final result = await mw.execute(
            CacheOperation$Write(key, bytes, httpCacheMeta: httpCacheMeta),
            ctx,
          );
          switch (result) {
            case CacheOperationResult$Write():
              return;
            case _:
              throw StateError(
                'Cache middleware returned ${result.runtimeType} for write; '
                'expected CacheOperationResult.Write',
              );
          }
        }
        await cache.write(key, bytes, httpCacheMeta: httpCacheMeta);
    }
  }

  static bool _hasAuthorizationHeader(Map<String, String>? headers) {
    switch (headers) {
      case null || Map(isEmpty: true):
        return false;
      case final map:
        for (final key in map.keys) {
          if (key.toLowerCase() == 'authorization') return true;
        }
        return false;
    }
  }
}

DateTime _defaultClock() => DateTime.now().toUtc();
