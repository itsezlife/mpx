import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cancel_token/cancel_token.dart';
import 'package:http/http.dart' as http;
import 'package:http_bytes_cache/src/bytes_cache.dart';
import 'package:http_bytes_cache/src/bytes_diagnostics.dart';
import 'package:http_bytes_cache/src/environment_specific/transfer_worker.dart'
    as environment_specific;
import 'package:http_bytes_cache/src/http/byte_range.dart';
import 'package:http_bytes_cache/src/http/http_bytes_transfer.dart';
import 'package:http_bytes_cache/src/http/http_bytes_upload.dart';
import 'package:http_bytes_cache/src/http/middlewares/retry_middleware.dart';
import 'package:http_bytes_cache/src/http/middlewares/timeout_middleware.dart';
import 'package:http_bytes_cache/src/http/request_priority.dart';
import 'package:http_bytes_cache/src/http/retry_backoff.dart';
import 'package:http_bytes_cache/src/http/transfer_worker.dart';
import 'package:meta/meta.dart';

/// Observes cumulative HTTP body bytes while a network GET consolidates.
///
/// [total] is the declared Content-Length, or null when the server sent none.
typedef BytesProgressCallback = void Function(int cumulative, int? total);

/// A function that takes an [HttpBytesRequest] and returns an [HttpBytesResponse].
/// [context] is shared across middleware for this send.
typedef HttpBytesHandler =
    Future<HttpBytesResponse> Function(
      HttpBytesRequest request,
      HttpBytesContext context,
    );

/// A function that takes an [HttpBytesHandler] and returns an [HttpBytesHandler].
typedef HttpBytesMiddleware =
    HttpBytesHandler Function(HttpBytesHandler innerHandler);

/// Ad-hoc [HttpBytesMiddleware] from optional request/response/error hooks,
/// plus [merge] for outermost-first chains.
// ignore: avoid-implicitly-nullable-extension-types, prefer-declaring-const-constructor
extension type HttpBytesMiddlewareWrapper._(HttpBytesMiddleware _fn) {
  /// Creates a new [HttpBytesMiddleware] from the given callbacks.
  factory HttpBytesMiddlewareWrapper({
    Future<void> Function(HttpBytesRequest request, HttpBytesContext context)?
    onRequest,
    Future<void> Function(HttpBytesResponse response, HttpBytesContext context)?
    onResponse,
    Future<void> Function(
      Object error,
      StackTrace stackTrace,
      HttpBytesContext context,
    )?
    onError,
  }) => HttpBytesMiddlewareWrapper._(
    (innerHandler) => (request, context) async {
      await onRequest?.call(request, context);
      try {
        final response = await innerHandler(request, context);
        await onResponse?.call(response, context);
        return response;
      } on Object catch (error, stackTrace) {
        await onError?.call(error, stackTrace, context);
        rethrow;
      }
    },
  );

  /// Merges [middlewares] into one [HttpBytesMiddleware].
  ///
  /// List order is outermost first: the first entry wraps every later one.
  factory HttpBytesMiddlewareWrapper.merge(
    List<HttpBytesMiddleware> middlewares,
  ) => HttpBytesMiddlewareWrapper._(switch (middlewares.length) {
    0 => (handler) => handler,
    1 => middlewares.single,
    _ => (handler) => middlewares.reversed.fold(
      handler,
      (handler, middleware) => middleware(handler),
    ),
  });

  /// Call the wrapped [HttpBytesMiddleware] with the given [innerHandler].
  HttpBytesHandler call(HttpBytesHandler innerHandler) => _fn(innerHandler);
}

/// Per-send middleware context: typed slots over a shared [Map].
///
/// Timeouts, retry flags, progress, conditional validators
/// ([etag] / [lastModified] for [HttpBytesConditionalMiddleware]), and
/// [identityOverride] (coalesce key from the resolver) live here. Seed slots
/// before [HttpBytesClient.send].
extension type HttpBytesContext(Map<String, Object?> _map)
    implements Map<String, Object?> {
  /// Empty context for a new send.
  factory HttpBytesContext.empty() => HttpBytesContext(<String, Object?>{});

  /// Shared flight [CancelToken] (AbortableRequest abort + Timeout).
  static const cancelTokenKey = 'cancelToken';

  /// Per-caller [CancelToken] for coalesce-aware cancel.
  static const callerCancelTokenKey = 'callerCancelToken';

  /// Connect timeout override ([Duration] / `int` ms / [DateTime] deadline).
  static const connectTimeoutKey = 'connect-timeout';

  /// Receive idle-gap timeout override ([Duration] / `int` ms / [DateTime]).
  static const receiveTimeoutKey = 'receive-timeout';

  /// This caller's progress sink. The flight fans body progress out to every
  /// sharer's sink, starting with a `0` report when the response starts.
  static const onBytesProgressKey = 'on-bytes-progress';

  /// Success predicate; default is 2xx or 304 Not Modified.
  static const validateStatusKey = 'validate-status';

  /// When `true`, [HttpBytesRetryMiddleware] skips retry for this send.
  static const noRetryKey = 'no-retry';

  /// Override [HttpBytesRetryBackoff.maxRetries] (`int` > 0).
  static const retriesKey = 'retries';

  /// When `true`, allow retry even if the method is not idempotent.
  static const retryNonIdempotentKey = 'retry-non-idempotent';

  /// Stored `ETag` validator for [HttpBytesConditionalMiddleware] (`If-None-Match`).
  static const etagKey = 'etag';

  /// Stored `Last-Modified` validator for [HttpBytesConditionalMiddleware]
  /// (`If-Modified-Since`).
  static const lastModifiedKey = 'last-modified';

  /// This caller's [PriorityToken] for the slot queue.
  static const priorityKey = 'priority';

  /// The [ByteRange] a range GET asks for ([HttpBytesClient.stream]).
  static const rangeKey = 'range';

  /// Explicit coalesce identity ([BytesCacheKey]). When set, post-middleware
  /// URL + headers are ignored for the in-flight key; headers still go on the
  /// wire. [BytesResolver] sets this from [BytesRequest.cacheKey].
  static const identityOverrideKey = 'identity-override';

  /// Shared flight [CancelToken] for this send (AbortableRequest abort + Timeout).
  ///
  /// Set when a flight starts (after post-middleware identity). Coalesced
  /// subscribers each keep their own [callerCancelToken]; Timeout cancels this
  /// flight token. Last-subscriber cancel also cancels it.
  CancelToken? get cancelToken => switch (_map[cancelTokenKey]) {
    final CancelToken t => t,
    _ => null,
  };
  set cancelToken(CancelToken? value) => _set(cancelTokenKey, value);

  /// Per-caller [CancelToken] for coalesce-aware cancel (not the flight abort).
  CancelToken? get callerCancelToken => switch (_map[callerCancelTokenKey]) {
    final CancelToken t => t,
    _ => null,
  };
  set callerCancelToken(CancelToken? value) =>
      _set(callerCancelTokenKey, value);

  /// This caller's priority; null means [RequestPriority.visible].
  PriorityToken? get priority => switch (_map[priorityKey]) {
    final PriorityToken t => t,
    _ => null,
  };
  set priority(PriorityToken? value) => _set(priorityKey, value);

  /// Connect timeout override ([Duration] / `int` ms / [DateTime] deadline).
  Object? get connectTimeout => _map[connectTimeoutKey];
  set connectTimeout(Object? value) => _set(connectTimeoutKey, value);

  /// Receive idle-gap timeout override ([Duration] / `int` ms / [DateTime]).
  Object? get receiveTimeout => _map[receiveTimeoutKey];
  set receiveTimeout(Object? value) => _set(receiveTimeoutKey, value);

  /// This caller's progress sink (see [onBytesProgressKey]).
  BytesProgressCallback? get onBytesProgress =>
      switch (_map[onBytesProgressKey]) {
        final BytesProgressCallback cb => cb,
        _ => null,
      };
  set onBytesProgress(BytesProgressCallback? value) =>
      _set(onBytesProgressKey, value);

  /// Success predicate; default is 2xx or 304 Not Modified.
  bool Function(int statusCode)? get validateStatus =>
      switch (_map[validateStatusKey]) {
        final bool Function(int statusCode) predicate => predicate,
        _ => null,
      };
  set validateStatus(bool Function(int statusCode)? value) =>
      _set(validateStatusKey, value);

  /// When `true`, [HttpBytesRetryMiddleware] skips retry for this send.
  bool get noRetry => _map[noRetryKey] == true;
  set noRetry(bool value) => _set(noRetryKey, value ? true : null);

  /// Override [HttpBytesRetryBackoff.maxRetries] (`int` > 0).
  int? get retries => switch (_map[retriesKey]) {
    final int r when r > 0 => r,
    _ => null,
  };
  set retries(int? value) => _set(retriesKey, value);

  /// When `true`, allow retry even if the method is not idempotent.
  bool get retryNonIdempotent => _map[retryNonIdempotentKey] == true;
  set retryNonIdempotent(bool value) =>
      _set(retryNonIdempotentKey, value ? true : null);

  /// Stored `ETag` for conditional GET. Non-empty → `If-None-Match` on the wire
  /// when [HttpBytesConditionalMiddleware] is in the stack. Not part of coalesce
  /// identity ([BytesCacheKey.canonicalHeaders] strips conditionals).
  String? get etag => switch (_map[etagKey]) {
    final String s when s.trim().isNotEmpty => s,
    _ => null,
  };
  set etag(String? value) => _set(etagKey, value);

  /// Stored `Last-Modified` for conditional GET. Non-empty → `If-Modified-Since`
  /// on the wire when [HttpBytesConditionalMiddleware] is in the stack. Wire-only;
  /// excluded from coalesce identity like [etag].
  String? get lastModified => switch (_map[lastModifiedKey]) {
    final String s when s.trim().isNotEmpty => s,
    _ => null,
  };
  set lastModified(String? value) => _set(lastModifiedKey, value);

  /// The range this GET asks for, or null for a full GET. Set by
  /// [HttpBytesClient.stream], which also puts the `Range` header on the
  /// request; middlewares read it to tell a range GET apart (the conditional
  /// middleware sends `If-Range` instead of `If-None-Match`).
  ByteRange? get range => switch (_map[rangeKey]) {
    final ByteRange r => r,
    _ => null,
  };
  set range(ByteRange? value) => _set(rangeKey, value);

  /// Explicit coalesce identity. When set, wins over post-middleware URL +
  /// headers for the in-flight key. Durable ladder keys use the same value via
  /// [BytesRequest.cacheKey]. Representation headers still hit the wire.
  /// Minting one override across different `Authorization` values is your
  /// responsibility.
  BytesCacheKey? get identityOverride => switch (_map[identityOverrideKey]) {
    final BytesCacheKey k => k,
    _ => null,
  };
  set identityOverride(BytesCacheKey? value) =>
      _set(identityOverrideKey, value);

  void _set(String key, Object? value) {
    if (value == null) {
      _map.remove(key);
    } else {
      _map[key] = value;
    }
  }
}

// --- Request / response ---

/// HTTP request wrapping a [http.BaseRequest].
///
/// Middlewares may [clone] to adjust method, URL, or headers while keeping the
/// same abort trigger when the underlying request is [http.Abortable].
extension type const HttpBytesRequest(http.BaseRequest _request)
    implements http.BaseRequest {
  /// Whether [clone] can replay this request for [HttpBytesRetryMiddleware].
  ///
  /// True for [http.Request] / [http.AbortableRequest] (buffered body). False
  /// for streamed/multipart bodies that cannot be re-sent after the first pass.
  bool get canBeRetried => switch (_request) {
    http.Request() => true,
    _ => false,
  };

  /// Creates a clone with optional parameter overrides.
  ///
  /// Preserves cancellation: rebuilds an [http.AbortableRequest] carrying the
  /// same [http.Abortable.abortTrigger] when present. Copies a buffered body
  /// when [source] is an [http.Request] so retries replay the same payload.
  HttpBytesRequest clone({
    String? method,
    Uri? url,
    Map<String, String>? headers,
    int? maxRedirects,
  }) {
    final source = _request;
    final abortTrigger = switch (source) {
      http.Abortable(:final abortTrigger?) => abortTrigger,
      _ => null,
    };
    final newRequest = switch (abortTrigger) {
      null => http.Request(method ?? source.method, url ?? source.url),
      final trigger => http.AbortableRequest(
        method ?? source.method,
        url ?? source.url,
        abortTrigger: trigger,
      ),
    };

    newRequest.headers.addAll(source.headers);
    if (headers case final h?) {
      newRequest.headers.addAll(h);
    }

    if (source case http.Request(:final bodyBytes)) {
      newRequest.bodyBytes = bodyBytes;
    }

    newRequest
      ..maxRedirects = maxRedirects ?? source.maxRedirects
      ..followRedirects = source.followRedirects;

    return HttpBytesRequest(newRequest);
  }
}

/// HTTP response from [HttpBytesClient]: status, headers, and body stream.
///
/// [stream] is single-subscription. After [_sendUnstreamed] finishes the body
/// for coalesce, [body] holds the same bytes so joiners can call [toBytes]
/// without re-listening.
@immutable
final class HttpBytesResponse {
  /// Create a new HTTP response.
  const HttpBytesResponse({
    required this.statusCode,
    required this.headers,
    required this.contentLength,
    required this.request,
    required this.stream,
    this.body,
  });

  /// HTTP status code.
  final int statusCode;

  /// Response headers as received.
  final Map<String, String> headers;

  /// Declared Content-Length when present; otherwise `0`.
  final int contentLength;

  /// The request that produced this response.
  final HttpBytesRequest request;

  /// Byte stream of the response body (single-subscription).
  final http.ByteStream stream;

  /// Consolidated body when the client has already consumed [stream].
  final Uint8List? body;

  /// Whether this is a `206 Partial Content` answer to a range GET.
  bool get isPartial => statusCode == 206;

  /// The parsed `Content-Range` of a `206`, or null.
  ContentRange? get contentRange =>
      isPartial ? ContentRange.parse(headers['content-range']) : null;

  /// Length of the whole representation: the `Content-Range` total of a
  /// `206`, else the declared length of a full body; null when unknown.
  int? get totalLength => switch (statusCode) {
    206 => contentRange?.totalLength,
    _ when contentLength > 0 => contentLength,
    _ => null,
  };

  /// Whether the server advertised `Accept-Ranges: bytes`. A `206` proves
  /// range support whatever the header says.
  bool get acceptsRanges =>
      isPartial ||
      (headers['accept-ranges']?.toLowerCase().contains('bytes') ?? false);

  /// Returns the response body as bytes.
  ///
  /// Prefers [body] when present; otherwise consumes [stream] (read once).
  Future<Uint8List> toBytes() => switch (body) {
    final cached? => Future<Uint8List>.value(cached),
    null => stream.toBytes(),
  };

  /// Creates a clone with optional parameter overrides.
  HttpBytesResponse clone({
    int? statusCode,
    Map<String, String>? headers,
    int? contentLength,
    HttpBytesRequest? request,
    http.ByteStream? stream,
    Uint8List? body,
  }) => HttpBytesResponse(
    statusCode: statusCode ?? this.statusCode,
    headers: headers ?? Map<String, String>.of(this.headers),
    contentLength: contentLength ?? this.contentLength,
    request: request ?? this.request,
    stream: stream ?? this.stream,
    body: body ?? this.body,
  );
}

// --- Client ---

/// {@template http_bytes_client}
/// HTTP GET for response bodies, with middlewares, concurrency cap, and
/// in-flight coalescing.
///
/// Concurrent callers that share the same **post-middleware** coalesce identity
/// join one in-flight GET. Identity is `BytesCacheKey` from the request URL +
/// headers after request-mutating middleware (e.g. Bearer) runs, unless
/// [HttpBytesContext.identityOverride] is set (resolver `cacheKey`). Then the
/// override wins for coalesce. Conditional request headers (`If-None-Match` /
/// `If-Modified-Since` / equivalents) are excluded from the URL+headers
/// fingerprint so local validators do not fragment flights. Each caller may
/// pass its own [CancelToken]:
/// - canceling one subscriber completes only that caller with
///   [HttpBytesException$Cancelled] and leaves the flight running;
/// - canceling the last subscriber cancels the shared flight token (socket
///   abort). Timeout middleware cancels that same flight token and still
///   surfaces [HttpBytesException$Timeout], not Cancelled.
///
/// Requests share [maxConcurrent] slots (8), of which GETs take at most
/// [maxDownloads] (6) and uploads at most [maxUploads] (6), so each direction
/// keeps 2 however busy the other is. Waiting GETs are served by priority
/// ([PriorityToken], read when a slot frees), then by arrival; a coalesced GET
/// takes the highest priority among its callers, and a GET whose last caller
/// cancels leaves the queue at once. Waiting uploads are served by arrival.
///
/// Status handling: default success is 2xx **or** 304 Not Modified. A 304
/// completes with headers and an empty body (illegal non-empty 304 bodies are
/// ignored). Empty-body-as-[HttpBytesException$Internal] still applies when a
/// successful body was expected (non-304).
///
/// With [transfers], [transfer] runs file-bound GETs on a worker isolate: the
/// socket, the body and the file writes stay there, and this isolate hears
/// the head and each span written. [client] then serves every other request.
///
/// [upload] sends a body streamed from a file range: on the VM from the
/// transfer worker (spawned for it with default [HttpBytesTransfers] when the
/// client was given none), on the web through `fetch`. Its bytes never enter
/// the calling isolate.
/// {@endtemplate}
final class HttpBytesClient {
  /// {@macro http_bytes_client}
  HttpBytesClient({
    http.Client? client,
    this.maxConcurrent = 8,
    this.maxDownloads = 6,
    this.maxUploads = 6,
    Iterable<HttpBytesMiddleware>? middlewares,
    this.validateStatus,
    HttpBytesTransfers? transfers,
  }) : assert(maxConcurrent > 0, 'maxConcurrent must be > 0'),
       assert(maxDownloads > 0, 'maxDownloads must be > 0'),
       assert(maxUploads > 0, 'maxUploads must be > 0'),
       _transfers = transfers,
       middlewares = List<HttpBytesMiddleware>.unmodifiable(
         middlewares ??
             <HttpBytesMiddleware>[const HttpBytesTimeoutMiddleware()],
       ) {
    final internalClient = client ?? http.Client();
    _ownsClient = client == null;
    _client = internalClient;
    _slots = _Slots(
      total: maxConcurrent,
      downloads: maxDownloads,
      uploads: maxUploads,
    );
    final pipeline = HttpBytesMiddlewareWrapper.merge([...this.middlewares]);
    // User middlewares (Bearer, Retry, Timeout, …) wrap coalesce+send so
    // identity sees post-middleware headers; joiners do not hold a pool slot.
    _handler = pipeline(_coalesceThenSend(validateStatus));
  }

  /// Process-wide default when nothing is injected.
  factory HttpBytesClient.shared() {
    _$ensureResetSharedCleanup();
    return debugShared ?? (_shared ??= HttpBytesClient());
  }

  static HttpBytesClient? _shared;

  /// Test override for [HttpBytesClient.shared]. Set to `null` to clear.
  @visibleForTesting
  static HttpBytesClient? debugShared;

  /// Sets the process-wide client (bootstrap).
  static Future<void> configure(HttpBytesClient client) async {
    _$ensureResetSharedCleanup();
    final previous = _shared;
    if (previous != null && !identical(previous, client)) {
      await previous.close();
    }
    _shared = client;
  }

  /// Closes the previous shared instance, then clears [configure] and [debugShared].
  @visibleForTesting
  static Future<void> resetShared() async {
    final previous = _shared;
    debugShared = null;
    await previous?.close();
    _shared = null;
  }

  static var _$resetSharedCleanupInstalled = false;

  static void _$ensureResetSharedCleanup() {
    if (_$resetSharedCleanupInstalled) return;
    _$resetSharedCleanupInstalled = true;
    BytesCache.addAfterResetShared(resetShared);
  }

  /// Requests running at once, both directions together.
  final int maxConcurrent;

  /// GETs running at once, within [maxConcurrent]: every GET, coalesced,
  /// streamed or a transfer.
  final int maxDownloads;

  /// Uploads ([upload]) running at once, within [maxConcurrent].
  final int maxUploads;

  late final http.Client _client;
  late final bool _ownsClient;
  late final _Slots _slots;
  final HttpBytesTransfers? _transfers;

  /// Spawned with the first transfer or VM upload.
  late final TransferWorker _worker = environment_specific.$transferWorker(
    _transfers ?? const HttpBytesTransfers(),
  );
  var _workerUsed = false;

  /// The worker on the VM, `fetch` on the web.
  late final UploadSender _uploader = environment_specific.$uploadSender(() {
    _workerUsed = true;
    return _worker;
  });

  /// Whether [transfer] is available: the client was given transfers, and
  /// the platform has isolates (not the web).
  bool get canTransfer =>
      _transfers != null && environment_specific.$canTransfer;

  /// Composed middleware chain ending at [http.Client.send].
  late final HttpBytesHandler _handler;

  final Map<String, _HttpBytesInFlight> _inFlight = {};

  var _closed = false;

  /// Immutable list of middlewares to apply for each send.
  final List<HttpBytesMiddleware> middlewares;

  /// Decides whether a response [statusCode] is a success.
  ///
  /// Defaults to 2xx **or** 304 Not Modified (revalidation success with no
  /// body). Overridable per request via [HttpBytesContext.validateStatus].
  final bool Function(int statusCode)? validateStatus;

  /// Whether a GET whose coalesce identity is [key] is queued or running.
  ///
  /// The identity is the override a resolver passes ([BytesRequest.cacheKey])
  /// or the post-middleware URL + headers fingerprint, so a request whose
  /// headers a middleware changes (Bearer) is found only by its override.
  bool isInFlight(BytesCacheKey key) => _inFlight.containsKey(key.value);

  /// Runs [request] through middlewares (delegates to [_sendUnstreamed]).
  ///
  /// [priority] places the GET in the slot queue (null: visible).
  Future<HttpBytesResponse> send(
    HttpBytesRequest request, {
    Map<String, Object?>? context,
    CancelToken? cancelToken,
    BytesProgressCallback? onBytesProgress,
    PriorityToken? priority,
  }) => _sendUnstreamed(
    url: request.url,
    headers: request.headers,
    context: context,
    cancelToken: cancelToken,
    onBytesProgress: onBytesProgress,
    priority: priority,
  );

  /// GETs [url] and returns the response with its body still streaming.
  ///
  /// For bodies too large to buffer and for ranged resources: pass [range]
  /// for a single-range GET (the `Range` header and
  /// [HttpBytesContext.range]). The answer may be a `206` with
  /// [HttpBytesResponse.contentRange], or a `200` with the whole body when the
  /// server ignores ranges or `If-Range` failed; a `416` fails as
  /// [HttpBytesException$Request] (`range_not_satisfiable`). Middlewares run
  /// as for [getBytes] (timeout covers headers and body idle gaps).
  ///
  /// A streamed GET is never coalesced: two callers get two GETs. It holds
  /// one of the [maxConcurrent] slots, queued by [priority], until its body
  /// ends, fails or its subscription is cancelled; cancelling the
  /// subscription or [cancelToken] aborts the socket. Listen to or cancel
  /// the body, or cancel [cancelToken], so the slot comes back.
  Future<HttpBytesResponse> stream(
    Uri url, {
    Map<String, String>? headers,
    ByteRange? range,
    CancelToken? cancelToken,
    BytesProgressCallback? onBytesProgress,
    PriorityToken? priority,
    Map<String, Object?>? context,
  }) async {
    if (_closed) {
      throw const HttpBytesException$Internal(
        code: 'closed',
        message: 'HttpBytesClient is closed.',
        statusCode: 0,
      );
    }
    final callerToken = cancelToken ?? CancelToken();
    final ctx = HttpBytesContext(context ?? <String, Object?>{})
      ..callerCancelToken = callerToken
      ..onBytesProgress = onBytesProgress
      ..range = range;
    ctx[_kStreamed] = true;
    if (priority != null) ctx.priority = priority;
    final request = http.Request('GET', url);
    if (headers case final h?) request.headers.addAll(h);
    if (range != null) request.headers['range'] = range.header;
    return _raceCallerCancel(
      callerToken,
      url,
      () => _handler(HttpBytesRequest(request), ctx),
    );
  }

  /// GETs [url] and returns the response body (delegates to [_sendUnstreamed]).
  ///
  /// Pass [context] to seed typed slots (e.g. [HttpBytesContext.identityOverride]
  /// for coalesce, [HttpBytesContext.etag] for conditional middleware).
  Future<Uint8List> getBytes(
    Uri url, {
    Map<String, String>? headers,
    BytesProgressCallback? onBytesProgress,
    CancelToken? cancelToken,
    Map<String, Object?>? context,
    PriorityToken? priority,
  }) async {
    final response = await _sendUnstreamed(
      url: url,
      headers: headers,
      cancelToken: cancelToken,
      onBytesProgress: onBytesProgress,
      context: context,
      priority: priority,
    );
    return response.toBytes();
  }

  /// GETs [url] on the transfer worker and completes with the head, the body
  /// held there until [HttpBytesTransfer.writeTo] writes it into a file (or
  /// [HttpBytesTransfer.cancel] drops it): the body never enters this
  /// isolate.
  ///
  /// [range] asks a single range, as [stream] does. The middlewares run on
  /// the request and up to the head (Bearer and conditional headers, the
  /// connect timeout, retries of a GET that failed before its head); the
  /// body's idle timeout is [HttpBytesTransfers.receiveTimeout]. A transfer
  /// is never coalesced and holds one of [maxConcurrent] slots, queued by
  /// [priority], until its body ends, fails or is cancelled; cancelling
  /// [cancelToken] aborts it at any point.
  ///
  /// Throws [UnsupportedError] unless [canTransfer].
  Future<HttpBytesTransfer> transfer(
    Uri url, {
    Map<String, String>? headers,
    ByteRange? range,
    CancelToken? cancelToken,
    PriorityToken? priority,
    Map<String, Object?>? context,
  }) async {
    if (!canTransfer) {
      throw UnsupportedError(
        'This HttpBytesClient has no transfer worker: give it '
        'HttpBytesTransfers (the VM only).',
      );
    }
    if (_closed) {
      throw const HttpBytesException$Internal(
        code: 'closed',
        message: 'HttpBytesClient is closed.',
        statusCode: 0,
      );
    }
    final callerToken = cancelToken ?? CancelToken();
    final ctx = HttpBytesContext(context ?? <String, Object?>{})
      ..callerCancelToken = callerToken
      ..range = range;
    ctx[_kTransfer] = true;
    if (priority != null) ctx.priority = priority;
    final request = http.Request('GET', url);
    if (headers case final h?) request.headers.addAll(h);
    if (range != null) request.headers['range'] = range.header;
    final head = await _raceCallerCancel(
      callerToken,
      url,
      () => _handler(HttpBytesRequest(request), ctx),
    );
    return (ctx[_kTransferBody]! as _Transfer)..head = head;
  }

  /// Sends [body] to [url] as the body of a [method] request (`POST`, `PUT`
  /// or `PATCH`) with [headers], and completes with the answer: its status,
  /// headers and body, read whole (a small body: over 1 MiB fails).
  ///
  /// The body streams from its source as the connection takes it: on the
  /// VM the transfer worker reads the file range, on the web `fetch` reads
  /// a slice of the OPFS file or the blob. [onBytesSent] hears the bytes
  /// sent so far against the body's length: 0 first, growing in steps of
  /// [HttpBytesTransfers.landBytes], the last report the length (on the web,
  /// which reports no upload progress, 0 then the length). A try that is
  /// retried starts again from 0.
  ///
  /// The middlewares run on the request as for a GET, with two changes: the
  /// connect timeout is off unless [context] sets one, since the head comes
  /// only after the whole body (the worker's
  /// [HttpBytesTransfers.receiveTimeout] bounds every gap without progress
  /// instead); and [HttpBytesRetryMiddleware] is skipped, since retries are
  /// [retry]'s. An upload holds one of [maxUploads] slots while it sends and
  /// none while it waits to retry; it is never coalesced.
  ///
  /// [retry] retries a try that failed on the network, timed out, or got a
  /// status [HttpBytesRetryMiddleware.defaultRetryEvaluator] calls transient
  /// (5xx, 429, 408), waiting [HttpBytesRetryBackoff.backoff] between tries;
  /// [HttpBytesRetryBackoff.uploadPart] is the preset for parts. Null sends
  /// once. [retryRandom] draws the jitter; [retryWait] waits each delay (by
  /// default a timer), a seam for a scheduler that ends waits early or late.
  /// Each try, each retry and a final failure report to
  /// [BytesDiagnostics.current] ([BytesLogOp.uploadStarted],
  /// [BytesLogOp.uploadRetry], [BytesLogOp.uploadGaveUp]).
  ///
  /// Cancelling [cancelToken] aborts the request, or the wait, and fails
  /// with [HttpBytesException$Cancelled]. A status that is not a success
  /// fails as [getBytes] does, with the answer's body in the exception's
  /// `data['body']`.
  Future<HttpBytesResponse> upload(
    Uri url, {
    required HttpBytesUploadBody body,
    String method = 'POST',
    Map<String, String>? headers,
    CancelToken? cancelToken,
    BytesProgressCallback? onBytesSent,
    HttpBytesRetryBackoff? retry,
    math.Random? retryRandom,
    Future<void> Function(Duration delay)? retryWait,
    Map<String, Object?>? context,
  }) async {
    if (_closed) {
      throw const HttpBytesException$Internal(
        code: 'closed',
        message: 'HttpBytesClient is closed.',
        statusCode: 0,
      );
    }
    final verb = method.toUpperCase();
    if (!_uploadMethods.contains(verb)) {
      throw ArgumentError.value(method, 'method', 'is not POST, PUT or PATCH');
    }
    if (body is HttpBytesUploadBody$Blob &&
        !environment_specific.$canSendBlobs) {
      throw UnsupportedError(
        'A blob body is for the web; on the VM upload a file.',
      );
    }
    final callerToken = cancelToken ?? CancelToken();
    final random = retryRandom ?? math.Random();
    final wait = retryWait ?? Future<void>.delayed;
    var slept = Duration.zero;
    for (var attempt = 0; ; attempt++) {
      BytesDiagnostics.current.report(
        BytesLogEvent(
          level: BytesLogLevel.debug,
          op: BytesLogOp.uploadStarted,
          message:
              'upload $verb ${url.scheme}://${url.host}: '
              '${body.length} bytes, try ${attempt + 1}',
          fields: <String, Object>{
            'method': verb,
            'bytes': body.length,
            'attempt': attempt + 1,
          },
        ),
      );
      try {
        return await _uploadOnce(
          url,
          method: verb,
          body: body,
          headers: headers,
          callerToken: callerToken,
          onBytesSent: onBytesSent,
          context: context,
        );
      } on Object catch (error, stackTrace) {
        if (error is HttpBytesException$Cancelled || callerToken.isCancelled) {
          rethrow;
        }
        final (status, code) = switch (error) {
          HttpBytesException(:final statusCode, :final code) => (
            statusCode,
            code,
          ),
          _ => (0, 'unknown_error'),
        };
        final delay = switch (retry) {
          final retry?
              when attempt < retry.maxRetries &&
                  _isRetryableUpload(error, attempt) =>
            retry.backoff(attempt, random),
          _ => null,
        };
        if (delay == null || !retry!.withinBudget(slept, delay)) {
          BytesDiagnostics.current.report(
            BytesLogEvent(
              level: BytesLogLevel.error,
              op: BytesLogOp.uploadGaveUp,
              message:
                  'upload $verb ${url.scheme}://${url.host} failed after '
                  '${attempt + 1} tries: $code ($status)',
              stackTrace: stackTrace,
              fields: <String, Object>{
                'attempts': attempt + 1,
                'status': status,
                'code': code,
              },
            ),
          );
          rethrow;
        }
        BytesDiagnostics.current.report(
          BytesLogEvent(
            level: BytesLogLevel.warning,
            op: BytesLogOp.uploadRetry,
            message:
                'upload $verb ${url.scheme}://${url.host} try ${attempt + 1} '
                'failed: $code ($status); retry in ${delay.inMilliseconds} ms',
            fields: <String, Object>{
              'attempt': attempt + 1,
              'delayMs': delay.inMilliseconds,
              'status': status,
              'code': code,
            },
          ),
        );
        await _raceCallerCancel(callerToken, url, () => wait(delay));
        slept += delay;
      }
    }
  }

  /// One try of [upload] through the middleware chain.
  Future<HttpBytesResponse> _uploadOnce(
    Uri url, {
    required String method,
    required HttpBytesUploadBody body,
    required Map<String, String>? headers,
    required CancelToken callerToken,
    required BytesProgressCallback? onBytesSent,
    required Map<String, Object?>? context,
  }) {
    // A fresh context per try: the chain fills slots (the flight token) a
    // retry must not inherit.
    final ctx = HttpBytesContext(<String, Object?>{...?context})
      ..callerCancelToken = callerToken
      ..noRetry = true;
    if (!ctx.containsKey(HttpBytesContext.connectTimeoutKey)) {
      ctx.connectTimeout = Duration.zero;
    }
    ctx[_kUpload] = _UploadPlan(body, onBytesSent);
    final request = http.Request(method, url);
    if (headers case final h?) request.headers.addAll(h);
    return _raceCallerCancel(
      callerToken,
      url,
      () => _handler(HttpBytesRequest(request), ctx),
    );
  }

  /// An [upload] try at the center of the chain: an upload slot, then the
  /// request sent by [_uploader].
  Future<HttpBytesResponse> _sendUpload(
    HttpBytesRequest request,
    HttpBytesContext context,
    CancelToken callerToken,
  ) async {
    final plan = context[_kUpload]! as _UploadPlan;
    final flightToken = CancelToken();
    context.cancelToken = flightToken;
    final flight = _HttpBytesInFlight(
      flightToken: flightToken,
      onAbandoned: () {},
    )..trackCaller(callerToken);

    await _slots.acquire(flight, upload: true);
    try {
      final length = plan.body.length;
      plan.onBytesSent?.call(0, length);
      final UploadAnswer answer;
      try {
        answer = await _uploader.upload(
          method: request.method,
          url: request.url,
          headers: request.headers,
          body: plan.body,
          abort: flightToken.whenCancel,
          onSent: (sent) => plan.onBytesSent?.call(sent, length),
        );
      } on TransferFailed catch (failure, stackTrace) {
        Error.throwWithStackTrace(
          _transferError(
            failure,
            request.url,
            (_transfers ?? const HttpBytesTransfers()).receiveTimeout,
            ioCode: 'read_failed',
          ),
          stackTrace,
        );
      }
      final isSuccess =
          context.validateStatus ?? validateStatus ?? _defaultValidateStatus;
      if (!isSuccess(answer.statusCode)) {
        throw _statusToException(
          answer.statusCode,
          answer.headers,
          request.url,
          body: answer.body,
        );
      }
      return HttpBytesResponse(
        statusCode: answer.statusCode,
        headers: answer.headers,
        contentLength: answer.body.length,
        request: request,
        stream: http.ByteStream.fromBytes(answer.body),
        body: answer.body,
      );
    } finally {
      _slots.release(upload: true);
    }
  }

  /// Seeds caller context and runs the middleware chain (coalesce at the center).
  ///
  /// Coalesce identity is taken from the request **after** request-mutating
  /// middleware. The flight [CancelToken] and [http.AbortableRequest] are
  /// created only when starting a new flight (not when joining). Starters
  /// return a streaming response through Timeout (receive idle works); the
  /// body is buffered here and fan-out to joiners uses that buffer.
  Future<HttpBytesResponse> _sendUnstreamed({
    required Uri url,
    Map<String, String>? headers,
    Map<String, Object?>? context,
    CancelToken? cancelToken,
    BytesProgressCallback? onBytesProgress,
    PriorityToken? priority,
  }) async {
    if (_closed) {
      throw const HttpBytesException$Internal(
        code: 'closed',
        message: 'HttpBytesClient is closed.',
        statusCode: 0,
      );
    }

    final callerToken = cancelToken ?? CancelToken();
    if (callerToken.isCancelled) {
      throw HttpBytesException$Cancelled(
        error: CancelledException(callerToken.reason),
        data: <String, Object?>{'url': url.toString()},
      );
    }

    final ctx = HttpBytesContext(context ?? <String, Object?>{})
      ..callerCancelToken = callerToken
      ..onBytesProgress = onBytesProgress;
    if (priority != null) ctx.priority = priority;

    // Plain Request through middleware so Bearer/Retry can mutate/clone headers
    // before coalesce; AbortableRequest is built when a flight starts.
    final request = http.Request('GET', url);
    if (headers case final h?) {
      request.headers.addAll(h);
    }

    try {
      // Race the caller's CancelToken so starters (who buffer after Timeout)
      // observe Cancelled even while blocked in send/toBytes. Joiners already
      // get Cancelled from their subscriber Future; racing twice is harmless.
      //
      // CancelToken.track is not used: CancelableOperation.fromFuture reports
      // error completions in a way that surfaces as uncaught async errors under
      // package:test even when op.value is awaited (wrong precision for our
      // $Cancelled mapping). Homemade race keeps one Future and typed errors.
      return await _raceCallerCancel(callerToken, url, () async {
        final response = await _handler(HttpBytesRequest(request), ctx);
        // Joiner: flight already completed with a buffered body.
        if (response.body != null) return response;

        final rawBytes = await response.toBytes();
        final flight = switch (ctx[_kInFlight]) {
          final _HttpBytesInFlight f => f,
          _ => null,
        };
        // 304 Not Modified: success with no body. RFC forbids a message body;
        // illegal non-empty payloads from misbehaving CDNs are ignored so they
        // cannot replace caller expectations (ladder reuses cached bytes).
        // Empty-body-as-Internal still applies when a successful body was
        // expected (non-304).
        final bytes = switch (response.statusCode) {
          304 => Uint8List(0),
          _ => rawBytes,
        };
        if (bytes.isEmpty && response.statusCode != 304) {
          final error = HttpBytesException$Internal(
            code: 'empty_body',
            message: 'Downloaded body is empty: $url',
            statusCode: response.statusCode,
            data: <String, Object?>{'url': url.toString()},
          );
          flight?.completeError(error, StackTrace.current);
          throw error;
        }
        final buffered = response.clone(
          stream: http.ByteStream.fromBytes(bytes),
          body: bytes,
          contentLength: response.statusCode == 304 ? 0 : null,
        );
        flight?.completeSuccess(buffered);
        return buffered;
      });
    } on Object catch (error, stackTrace) {
      // Per-caller cancel must not fail remaining coalesce joiners.
      if (error case HttpBytesException$Cancelled()) {
        rethrow;
      }
      if (ctx[_kInFlight] case final _HttpBytesInFlight flight) {
        flight.completeError(error, stackTrace);
      }
      rethrow;
    }
  }

  /// Innermost handler: post-middleware identity → join or pool+Client.send.
  ///
  /// Starters return the streaming [HttpBytesResponse] so Timeout can wrap
  /// receive-idle on the body; [_sendUnstreamed] buffers and completes the
  /// flight. Joiners return a subscriber [Future] of the buffered result.
  HttpBytesHandler _coalesceThenSend(
    bool Function(int statusCode)? validateStatusDefault,
  ) {
    final clientSend = _createClientSend(_client, validateStatusDefault);

    return (request, context) async {
      final callerToken = context.callerCancelToken ?? CancelToken();
      if (context[_kStreamed] == true) {
        return _sendStreamed(clientSend, request, context, callerToken);
      }
      if (context[_kTransfer] == true) {
        return _sendTransfer(request, context, callerToken);
      }
      if (context[_kUpload] != null) {
        return _sendUpload(request, context, callerToken);
      }

      // Explicit override (resolver cacheKey) wins for coalesce; otherwise
      // fingerprint post-middleware URL + headers (Bearer Auth participates;
      // conditionals are stripped inside BytesCacheKey.canonicalHeaders).
      final key =
          context.identityOverride?.value ??
          BytesCacheKey.fromUrl(
            request.url.toString(),
            headers: request.headers,
          ).value;

      final existing = _inFlight[key];
      if (existing != null) {
        return existing.addSubscriber(
          callerToken,
          request.url,
          onProgress: context.onBytesProgress,
          priority: context.priority,
        );
      }

      final flightToken = CancelToken();
      context.cancelToken = flightToken;

      final abortable = http.AbortableRequest(
        'GET',
        request.url,
        abortTrigger: flightToken.whenCancel,
      )..headers.addAll(request.headers);

      final flight = _HttpBytesInFlight(
        flightToken: flightToken,
        onAbandoned: () => _inFlight.remove(key),
      );
      _inFlight[key] = flight;
      context[_kInFlight] = flight;
      // Starter: cancel interest only (result comes from streaming → buffer).
      // Do not attach a subscriber Future — that would uncaught-error on
      // completeError while getBytes already rethrows the same failure.
      flight.trackCaller(
        callerToken,
        onProgress: context.onBytesProgress,
        priority: context.priority,
      );

      unawaited(
        flight.done.whenComplete(() {
          _inFlight.remove(key);
        }),
      );

      try {
        return await _slots.run(
          flight,
          () => clientSend(HttpBytesRequest(abortable), context),
        );
      } on Object catch (error, stackTrace) {
        flight.completeError(error, stackTrace);
        rethrow;
      }
    };
  }

  /// A [stream] GET: its own flight (never shared), a slot held until the
  /// body ends, and a body that maps an abort to [HttpBytesException$Cancelled].
  Future<HttpBytesResponse> _sendStreamed(
    HttpBytesHandler clientSend,
    HttpBytesRequest request,
    HttpBytesContext context,
    CancelToken callerToken,
  ) async {
    final flightToken = CancelToken();
    context.cancelToken = flightToken;
    final abortable = http.AbortableRequest(
      'GET',
      request.url,
      abortTrigger: flightToken.whenCancel,
    )..headers.addAll(request.headers);
    final flight = _HttpBytesInFlight(
      flightToken: flightToken,
      onAbandoned: () {},
    );
    context[_kInFlight] = flight;
    flight.trackCaller(
      callerToken,
      onProgress: context.onBytesProgress,
      priority: context.priority,
    );

    await _slots.acquire(flight);
    var released = false;
    void release() {
      if (released) return;
      released = true;
      _slots.release();
    }

    unawaited(flightToken.whenCancel.then((_) => release()));
    final HttpBytesResponse response;
    try {
      response = await clientSend(HttpBytesRequest(abortable), context);
    } on Object {
      release();
      rethrow;
    }
    return response.clone(
      stream: http.ByteStream(
        _slotBoundBody(
          response.stream,
          url: request.url,
          onEnd: release,
          onAbandon: () {
            release();
            flightToken.cancel();
          },
        ),
      ),
    );
  }

  /// A [transfer] GET: its own flight (never shared), a slot held until the
  /// body ends, and the request sent from the transfer worker. The head
  /// comes back as a response with no body; the body waits on the worker
  /// for the [_Transfer] left in [context].
  Future<HttpBytesResponse> _sendTransfer(
    HttpBytesRequest request,
    HttpBytesContext context,
    CancelToken callerToken,
  ) async {
    final flightToken = CancelToken();
    context.cancelToken = flightToken;
    final flight = _HttpBytesInFlight(
      flightToken: flightToken,
      onAbandoned: () {},
    )..trackCaller(callerToken, priority: context.priority);

    await _slots.acquire(flight);
    var released = false;
    void release() {
      if (released) return;
      released = true;
      _slots.release();
    }

    unawaited(flightToken.whenCancel.then((_) => release()));
    _workerUsed = true;
    final record = _TransferLog(
      url: request.url,
      range: request.headers['range'],
      onTransfer: _transfers!.onTransfer,
    );
    final TransferHead remote;
    try {
      remote = await _worker.get(
        request.url,
        request.headers,
        abort: flightToken.whenCancel,
      );
    } on TransferFailed catch (failure, stackTrace) {
      release();
      record.end(failed: true);
      Error.throwWithStackTrace(
        _transferError(failure, request.url, _transfers.receiveTimeout),
        stackTrace,
      );
    }
    record.head(remote.statusCode);
    final isSuccess =
        context.validateStatus ?? validateStatus ?? _defaultValidateStatus;
    if (!isSuccess(remote.statusCode)) {
      _worker.discard(remote);
      release();
      record.end(failed: true);
      throw _statusToException(remote.statusCode, remote.headers, request.url);
    }
    context[_kTransferBody] = _Transfer(
      worker: _worker,
      remote: remote,
      cancelled: () => callerToken.isCancelled || flightToken.isCancelled,
      url: request.url,
      receiveTimeout: _transfers.receiveTimeout,
      release: release,
      record: record,
    );
    return HttpBytesResponse(
      statusCode: remote.statusCode,
      headers: remote.headers,
      contentLength: remote.contentLength ?? 0,
      request: request,
      stream: const http.ByteStream(Stream<List<int>>.empty()),
    );
  }

  /// Closes the slot queue and, when this instance created the client, the
  /// client. Queued GETs fail; running ones finish first. A transfer worker
  /// ends with the transfers it still runs.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _slots.close();
    if (_ownsClient) {
      _client.close();
    }
    if (_workerUsed) _worker.close();
  }
}

/// Context marker for a [HttpBytesClient.transfer] GET.
const _kTransfer = 'httpBytesTransfer';

/// Context slot for the [_UploadPlan] of a [HttpBytesClient.upload] try.
const _kUpload = 'httpBytesUpload';

/// Methods [HttpBytesClient.upload] sends.
const _uploadMethods = <String>{'POST', 'PUT', 'PATCH'};

/// What an upload try sends and who hears its progress.
final class _UploadPlan {
  const _UploadPlan(this.body, this.onBytesSent);

  final HttpBytesUploadBody body;
  final BytesProgressCallback? onBytesSent;
}

/// Whether an upload try that failed with [error] is worth another: what
/// the retry middleware retries, and a timeout too. The middleware cannot
/// retry a timeout because the flight it would retry on is already
/// cancelled; each upload try has a flight of its own, and a stalled send
/// is the commonest failure of a part.
bool _isRetryableUpload(Object error, int attempt) => switch (error) {
  HttpBytesException$Timeout() => true,
  _ => HttpBytesRetryMiddleware.defaultRetryEvaluator(error, attempt),
};

/// Context slot for the [_Transfer] a transfer's head leaves behind.
const _kTransferBody = 'httpBytesTransferBody';

/// The [HttpBytesException] a transfer that ended without its body throws.
HttpBytesException _transferError(
  TransferFailed failure,
  Uri url,
  Duration receiveTimeout, {
  String ioCode = 'write_failed',
}) {
  final data = <String, Object?>{'url': url.toString()};
  return switch (failure.kind) {
    TransferFailure.network => HttpBytesException$Network(
      code: 'network_error',
      message: failure.message,
      statusCode: 0,
      error: failure,
      data: data,
    ),
    TransferFailure.timeout => HttpBytesException$Timeout(
      code: 'receive_timeout',
      message: failure.message,
      statusCode: 408,
      duration: receiveTimeout,
      error: failure,
      data: data,
    ),
    TransferFailure.io => HttpBytesException$Internal(
      code: ioCode,
      message: failure.message,
      statusCode: 0,
      error: failure,
      data: data,
    ),
    TransferFailure.cancelled => HttpBytesException$Cancelled(
      error: failure,
      data: data,
    ),
  };
}

/// One transfer's body on the worker, as [HttpBytesClient.transfer] hands
/// it out.
final class _Transfer implements HttpBytesTransfer {
  _Transfer({
    required TransferWorker worker,
    required TransferHead remote,
    required bool Function() cancelled,
    required Uri url,
    required Duration receiveTimeout,
    required void Function() release,
    required _TransferLog record,
  }) : _worker = worker,
       _remote = remote,
       _cancelled = cancelled,
       _url = url,
       _receiveTimeout = receiveTimeout,
       _release = release,
       _record = record;

  final TransferWorker _worker;
  final TransferHead _remote;
  final bool Function() _cancelled;
  final Uri _url;
  final Duration _receiveTimeout;
  final void Function() _release;
  final _TransferLog _record;
  var _used = false;

  @override
  late final HttpBytesResponse head;

  @override
  Future<void> writeTo(
    String path, {
    required int offset,
    required FutureOr<void> Function(int start, int end) onLanded,
  }) async {
    _use();
    // Cancelled since the head: the abort may still be on its way to the
    // worker, which would otherwise write a body nobody wants.
    if (_cancelled()) {
      _drop();
      throw HttpBytesException$Cancelled(
        data: <String, Object?>{'url': _url.toString()},
      );
    }
    var failed = true;
    try {
      await _worker.write(_remote, path, offset, (start, end) {
        _record.bytes += end - start;
        return onLanded(start, end);
      });
      failed = false;
    } on TransferFailed catch (failure, stackTrace) {
      Error.throwWithStackTrace(
        _transferError(failure, _url, _receiveTimeout),
        stackTrace,
      );
    } finally {
      _release();
      _record.end(failed: failed);
    }
  }

  @override
  void cancel() {
    _use();
    _drop();
  }

  void _drop() {
    _worker.discard(_remote);
    _release();
    _record.end(failed: true);
  }

  void _use() {
    if (_used) throw StateError('A transfer is written or cancelled once.');
    _used = true;
  }
}

/// The timings of one transfer, reported once when it ends.
final class _TransferLog {
  _TransferLog({required this.url, required this.range, this.onTransfer});

  final Uri url;
  final String? range;
  final void Function(HttpBytesTransferRecord record)? onTransfer;
  final DateTime started = DateTime.now();
  final Stopwatch _clock = Stopwatch()..start();
  int statusCode = 0;
  Duration? _head;
  int bytes = 0;
  var _ended = false;

  void head(int status) {
    statusCode = status;
    _head = _clock.elapsed;
  }

  void end({required bool failed}) {
    if (_ended) return;
    _ended = true;
    onTransfer?.call(
      HttpBytesTransferRecord(
        url: url,
        range: range,
        statusCode: statusCode,
        started: started,
        head: _head,
        ended: _clock.elapsed,
        bytes: bytes,
        failed: failed,
      ),
    );
  }
}

/// Context slot for the in-flight entry started by coalesce (starter path).
const _kInFlight = 'httpBytesInFlight';

/// Context marker for a [HttpBytesClient.stream] GET: no coalesce, no buffer.
const _kStreamed = 'httpBytesStreamed';

/// Forwards [source], calling [onEnd] once it ends or fails and [onAbandon]
/// when the listener cancels first. An aborted socket surfaces as
/// [HttpBytesException$Cancelled], like an abort before the headers.
Stream<List<int>> _slotBoundBody(
  Stream<List<int>> source, {
  required Uri url,
  required void Function() onEnd,
  required void Function() onAbandon,
}) {
  StreamSubscription<List<int>>? subscription;
  var ended = false;
  late final StreamController<List<int>> controller;
  controller = StreamController<List<int>>(
    onListen: () {
      subscription = source.listen(
        controller.add,
        onError: (Object error, StackTrace stackTrace) {
          ended = true;
          onEnd();
          controller.addError(
            switch (error) {
              http.RequestAbortedException() => HttpBytesException$Cancelled(
                error: error,
                data: <String, Object?>{'url': url.toString()},
              ),
              _ => error,
            },
            stackTrace,
          );
        },
        onDone: () {
          ended = true;
          onEnd();
          unawaited(controller.close());
        },
      );
    },
    onPause: () => subscription?.pause(),
    onResume: () => subscription?.resume(),
    onCancel: () {
      if (!ended) onAbandon();
      return subscription?.cancel();
    },
  );
  return controller.stream;
}

/// One coalesced in-flight GET with N caller subscribers.
///
/// [flightToken] is the AbortableRequest abort signal and the context token
/// Timeout cancels. The starter [trackCaller]s for last-subscriber abort only;
/// joiners [addSubscriber] and await a Future. Canceling one caller drops that
/// subscriber; canceling the last cancels [flightToken] so the socket aborts.
///
/// Progress belongs to the flight, not to the caller that started it: the body
/// stream reports into [reportProgress], which fans out to every live
/// subscriber. A joiner that arrives mid-body first hears the last value, so
/// its progress does not sit at nothing until the next chunk. A cancelled
/// subscriber stops hearing; the others keep going.
final class _HttpBytesInFlight {
  _HttpBytesInFlight({
    required this.flightToken,
    required this.onAbandoned,
  });

  final CancelToken flightToken;
  final void Function() onAbandoned;

  final Completer<HttpBytesResponse> _flight = Completer<HttpBytesResponse>();
  final Set<_HttpBytesSubscriber> _subscribers = <_HttpBytesSubscriber>{};

  /// Last `(cumulative, total)` reported, replayed to late joiners.
  (int, int?)? _lastProgress;

  /// Completes when the shared GET finishes (success or error), after fan-out.
  Future<void> get done =>
      _flight.future.then<void>((_) {}, onError: (_, _) {});

  /// Starter: count toward last-subscriber abort without a result Future.
  void trackCaller(
    CancelToken callerToken, {
    BytesProgressCallback? onProgress,
    PriorityToken? priority,
  }) {
    final subscriber = _HttpBytesSubscriber(
      token: callerToken,
      onProgress: onProgress,
      priority: priority,
    );
    _subscribers.add(subscriber);
    unawaited(
      callerToken.whenCancel.then((_) {
        _removeSubscriber(subscriber);
      }),
    );
  }

  /// Joiner: track cancel + Future of the buffered flight result.
  Future<HttpBytesResponse> addSubscriber(
    CancelToken callerToken,
    Uri url, {
    BytesProgressCallback? onProgress,
    PriorityToken? priority,
  }) {
    final completer = Completer<HttpBytesResponse>();
    final subscriber = _HttpBytesSubscriber(
      token: callerToken,
      completer: completer,
      onProgress: onProgress,
      priority: priority,
    );
    _subscribers.add(subscriber);
    if ((onProgress, _lastProgress) case (final sink?, (final c, final t)?)) {
      sink(c, t);
    }

    // Fan-out flight result to this subscriber if still waiting.
    _flight.future.then(
      (response) {
        if (!completer.isCompleted) {
          completer.complete(response);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      },
    );

    // Per-caller cancel: drop this subscriber; abort flight only when last.
    unawaited(
      callerToken.whenCancel.then((_) {
        if (completer.isCompleted) return;
        completer.completeError(
          HttpBytesException$Cancelled(
            error: CancelledException(callerToken.reason),
            data: <String, Object?>{'url': url.toString()},
          ),
        );
        _removeSubscriber(subscriber);
      }),
    );

    return completer.future;
  }

  /// The highest priority among live subscribers, read when a slot frees.
  RequestPriority get priority {
    var best = RequestPriority.background;
    for (final subscriber in _subscribers) {
      final mine = subscriber.priority?.priority ?? RequestPriority.visible;
      if (mine.isAbove(best)) best = mine;
    }
    return best;
  }

  /// Fans one body progress report out to every live subscriber.
  void reportProgress(int cumulative, int? total) {
    _lastProgress = (cumulative, total);
    for (final subscriber in List.of(_subscribers)) {
      subscriber.onProgress?.call(cumulative, total);
    }
  }

  void completeSuccess(HttpBytesResponse response) {
    if (_flight.isCompleted) return;
    _flight.complete(response);
    _subscribers.clear();
  }

  void completeError(Object error, StackTrace stackTrace) {
    if (_flight.isCompleted) return;
    final wrapped = switch (error) {
      final HttpBytesException e => e,
      _ => HttpBytesException$Internal(
        code: 'unknown_error',
        message: 'Unknown error.',
        statusCode: 0,
        error: error,
      ),
    };
    _flight.completeError(wrapped, stackTrace);
    _subscribers.clear();
  }

  void _removeSubscriber(_HttpBytesSubscriber subscriber) {
    if (!_subscribers.remove(subscriber)) return;
    if (_subscribers.isNotEmpty || _flight.isCompleted) return;
    // Last live subscriber cancelled before the flight finished — abort socket
    // and drop the coalesce key so a new caller starts a fresh GET.
    onAbandoned();
    flightToken.cancel();
  }
}

final class _HttpBytesSubscriber {
  _HttpBytesSubscriber({
    required this.token,
    this.completer,
    this.onProgress,
    this.priority,
  });

  final CancelToken token;

  /// This caller's priority; null means visible.
  final PriorityToken? priority;

  /// This caller's progress sink, if it asked for one.
  final BytesProgressCallback? onProgress;

  /// Non-null for joiners; starters track cancel only.
  final Completer<HttpBytesResponse>? completer;
}

/// The [HttpBytesClient]'s concurrency caps: [total] slots for both
/// directions, at most [downloads] of them GETs and [uploads] of them
/// uploads, each direction with a queue of its own.
///
/// GETs are served by flight priority, then arrival; uploads by arrival
/// (their scheduler orders them before they get here). When one slot frees
/// and both directions wait, the earlier arrival gets it. Priorities are
/// read when a slot frees, not when a GET queues, so a caller raising its
/// [PriorityToken] overtakes work queued before it. A queued flight whose
/// token cancels (its last caller left) leaves the queue at once instead of
/// waiting for a slot only to abort. A homemade queue rather than
/// `package:pool`: that pool is first-in first-out with no reordering and
/// one cap.
final class _Slots {
  _Slots({required this.total, required this.downloads, required this.uploads});

  final int total;
  final int downloads;
  final int uploads;
  var _activeDownloads = 0;
  var _activeUploads = 0;
  var _arrivals = 0;
  var _closed = false;
  final List<_SlotWaiter> _downloadQueue = [];
  final List<_SlotWaiter> _uploadQueue = [];
  Completer<void>? _idle;

  int get _active => _activeDownloads + _activeUploads;

  Future<T> run<T>(
    _HttpBytesInFlight flight,
    Future<T> Function() work,
  ) async {
    await acquire(flight);
    try {
      return await work();
    } finally {
      release();
    }
  }

  /// Gives back a slot [acquire] took for the same direction.
  void release({bool upload = false}) {
    if (upload) {
      _activeUploads--;
    } else {
      _activeDownloads--;
    }
    _dispatch();
  }

  bool _hasRoom({required bool upload}) =>
      _active < total &&
      (upload ? _activeUploads < uploads : _activeDownloads < downloads);

  /// Takes a slot for [flight] in its direction, waiting in that
  /// direction's queue when none is free.
  Future<void> acquire(_HttpBytesInFlight flight, {bool upload = false}) {
    if (_closed) {
      return Future<void>.error(
        const HttpBytesException$Internal(
          code: 'closed',
          message: 'HttpBytesClient is closed.',
          statusCode: 0,
        ),
      );
    }
    final queue = upload ? _uploadQueue : _downloadQueue;
    if (queue.isEmpty && _hasRoom(upload: upload)) {
      _take(upload: upload);
      return Future<void>.value();
    }
    final waiter = _SlotWaiter(flight, _arrivals++, upload: upload);
    queue.add(waiter);
    unawaited(
      flight.flightToken.whenCancel.then((_) {
        if (!queue.remove(waiter)) return;
        waiter.completer.completeError(
          HttpBytesException$Cancelled(
            error: CancelledException(flight.flightToken.reason),
          ),
        );
      }),
    );
    return waiter.completer.future;
  }

  void _take({required bool upload}) {
    if (upload) {
      _activeUploads++;
    } else {
      _activeDownloads++;
    }
  }

  /// The GET to serve next: highest priority, then earliest arrival (the
  /// queue is kept in arrival order).
  _SlotWaiter? get _nextDownload {
    if (_downloadQueue.isEmpty || !_hasRoom(upload: false)) return null;
    var next = _downloadQueue.first;
    var nextPriority = next.flight.priority;
    for (final waiter in _downloadQueue.skip(1)) {
      final priority = waiter.flight.priority;
      if (priority.isAbove(nextPriority)) {
        next = waiter;
        nextPriority = priority;
      }
    }
    return next;
  }

  _SlotWaiter? get _nextUpload =>
      _uploadQueue.isEmpty || !_hasRoom(upload: true)
      ? null
      : _uploadQueue.first;

  void _dispatch() {
    while (true) {
      final next = switch ((_nextDownload, _nextUpload)) {
        (null, null) => null,
        (final download?, null) => download,
        (null, final upload?) => upload,
        (final download?, final upload?) =>
          download.arrival < upload.arrival ? download : upload,
      };
      if (next == null) break;
      (next.upload ? _uploadQueue : _downloadQueue).remove(next);
      _take(upload: next.upload);
      next.completer.complete();
    }
    if (_active == 0) {
      _idle?.complete();
      _idle = null;
    }
  }

  Future<void> close() async {
    _closed = true;
    final queued = [..._downloadQueue, ..._uploadQueue];
    _downloadQueue.clear();
    _uploadQueue.clear();
    for (final waiter in queued) {
      waiter.completer.completeError(
        const HttpBytesException$Internal(
          code: 'closed',
          message: 'HttpBytesClient is closed.',
          statusCode: 0,
        ),
      );
    }
    if (_active == 0) return;
    await (_idle ??= Completer<void>()).future;
  }
}

final class _SlotWaiter {
  _SlotWaiter(this.flight, this.arrival, {required this.upload});

  final _HttpBytesInFlight flight;

  /// Order of arrival across both queues.
  final int arrival;

  /// Whether this waits for an upload slot.
  final bool upload;

  final Completer<void> completer = Completer<void>();
}

/// Completes with [HttpBytesException$Cancelled] when [token] cancels, or with
/// [work]'s result otherwise. Late work errors after cancel are swallowed so
/// an abandoned starter send cannot surface as an uncaught async error.
///
/// Prefer this over [CancelToken.track]: `CancelableOperation.fromFuture` can
/// report completions as uncaught zone errors under test even when `.value` is
/// awaited, and it does not map cancel to [HttpBytesException$Cancelled].
Future<T> _raceCallerCancel<T>(
  CancelToken token,
  Uri url,
  Future<T> Function() work,
) {
  if (token.isCancelled) {
    return Future<T>.error(
      HttpBytesException$Cancelled(
        error: CancelledException(token.reason),
        data: <String, Object?>{'url': url.toString()},
      ),
    );
  }

  final done = Completer<T>();
  unawaited(
    token.whenCancel.then((_) {
      if (!done.isCompleted) {
        done.completeError(
          HttpBytesException$Cancelled(
            error: CancelledException(token.reason),
            data: <String, Object?>{'url': url.toString()},
          ),
        );
      }
    }),
  );
  work().then(
    (value) {
      if (!done.isCompleted) done.complete(value);
    },
    onError: (Object error, StackTrace stackTrace) {
      if (!done.isCompleted) {
        done.completeError(error, stackTrace);
      }
    },
  );
  return done.future;
}

/// Client.send + status map + progress. Pool/coalesce live in
/// [HttpBytesClient._coalesceThenSend]; user middlewares wrap that.
HttpBytesHandler _createClientSend(
  http.Client internalClient,
  bool Function(int statusCode)? validateStatusDefault,
) {
  void throwError(
    Completer<HttpBytesResponse> completer,
    Object error,
    StackTrace stackTrace,
  ) {
    if (completer.isCompleted) return;
    completer.completeError(
      switch (error) {
        final HttpBytesException e => e,
        _ => HttpBytesException$Internal(
          code: 'unknown_error',
          message: 'Unknown error.',
          statusCode: 0,
          error: error,
        ),
      },
      stackTrace,
    );
  }

  Future<HttpBytesResponse> httpHandler(
    HttpBytesRequest request,
    HttpBytesContext context,
  ) {
    final completer = Completer<HttpBytesResponse>();

    // runZonedGuarded routes async errors that escape the inner try/catch through throwError.
    runZonedGuarded<void>(
      () async {
        final http.StreamedResponse streamedResponse;
        try {
          streamedResponse = await internalClient.send(request._request);
        } on http.RequestAbortedException catch (error, stackTrace) {
          // The request was cancelled via a CancelToken — surface it distinctly
          // so callers and HttpBytesRetryMiddleware can tell it apart from a real failure.
          throwError(
            completer,
            HttpBytesException$Cancelled(
              error: error,
              data: <String, Object?>{'url': request.url.toString()},
            ),
            stackTrace,
          );
          return;
        } on Object catch (error, stackTrace) {
          throwError(
            completer,
            HttpBytesException$Network(
              code: 'network_error',
              message: 'Failed to send request due to a network error.',
              statusCode: 0,
              error: error,
              data: <String, Object?>{'url': request.url.toString()},
            ),
            stackTrace,
          );
          return;
        }

        final statusCode = streamedResponse.statusCode;
        final isSuccess =
            context.validateStatus ??
            validateStatusDefault ??
            _defaultValidateStatus;
        if (!isSuccess(statusCode)) {
          unawaited(streamedResponse.stream.drain<void>());
          throwError(
            completer,
            _statusToException(
              statusCode,
              streamedResponse.headers,
              request.url,
            ),
            StackTrace.current,
          );
          return;
        }

        final contentLength = streamedResponse.contentLength ?? 0;
        var byteStream = streamedResponse.stream;

        // 304: RFC forbids a body. Skip progress on any illegal payload; the
        // buffer path will force an empty body before fan-out.
        final isNotModified = statusCode == 304;

        // Report download progress to the flight, which fans it out to every
        // sharer. `total` is the Content-Length, or `null` when the server did
        // not declare one. The 0 report marks the transfer start, so a sharer
        // can show an empty arc before the first chunk lands.
        if (context[_kInFlight] case final _HttpBytesInFlight flight
            when !isNotModified) {
          final total = contentLength > 0 ? contentLength : null;
          var received = 0;
          flight.reportProgress(0, total);
          byteStream = http.ByteStream(
            byteStream.map((chunk) {
              received += chunk.length;
              flight.reportProgress(received, total);
              return chunk;
            }),
          );
        }

        if (!completer.isCompleted) {
          completer.complete(
            HttpBytesResponse(
              statusCode: statusCode,
              headers: Map<String, String>.from(streamedResponse.headers),
              contentLength: isNotModified ? 0 : contentLength,
              request: request,
              stream: byteStream,
            ),
          );
        }
      },
      (error, stackTrace) {
        throwError(completer, error, stackTrace);
      },
    );

    return completer.future;
  }

  return httpHandler;
}

/// Default success predicate for GETs: 2xx, or 304 Not Modified.
///
/// 304 is a first-class revalidation success (headers present; body optional
/// and ignored). Without it, conditional GETs would surface as `$Request` and
/// Retry would never see a clean success.
bool _defaultValidateStatus(int statusCode) =>
    (statusCode >= 200 && statusCode < 300) || statusCode == 304;

/// Maps a non-success [statusCode] to a typed [HttpBytesException].
///
/// Total over every non-success code (caller needs no fallback): 401/403 →
/// [HttpBytesException$Authentication]; 5xx → [HttpBytesException$Server];
/// everything else (4xx and any other non-2xx) → [HttpBytesException$Request].
/// Transport failures with no HTTP response are [HttpBytesException$Network]
/// from the send catch, not here.
///
/// Byte GETs do not parse an error body (payloads are drained); [data] still
/// carries `url`, `headers`, and `retry-after` when present on 429/503.
HttpBytesException _statusToException(
  int statusCode,
  Map<String, String> headers,
  Uri url, {
  Uint8List? body,
}) {
  final (code, message) = _codeAndMessageFor(statusCode);
  final data = <String, Object?>{
    'url': url.toString(),
    'headers': headers,
    'body': ?body,
    if (statusCode == 429 || statusCode == 503)
      'retry-after': ?headers['retry-after'],
  };
  return switch (statusCode) {
    401 || 403 => HttpBytesException$Authentication(
      code: code,
      message: message,
      statusCode: statusCode,
      data: data,
    ),
    >= 500 => HttpBytesException$Server(
      code: code,
      message: message,
      statusCode: statusCode,
      data: data,
    ),
    _ => HttpBytesException$Request(
      code: code,
      message: message,
      statusCode: statusCode,
      data: data,
    ),
  };
}

/// Per-code semantic `(code, message)` for a non-success HTTP [statusCode].
/// Unlisted codes fall back to a generic server (5xx) or client label.
(String, String) _codeAndMessageFor(int statusCode) => switch (statusCode) {
  416 => (
    'range_not_satisfiable',
    'Range not satisfiable (HTTP 416). The range starts past the end.',
  ),
  503 => (
    'service_unavailable',
    'Service unavailable (HTTP 503). The server is currently unable to handle the request.',
  ),
  500 => ('internal_server_error', 'Internal server error (HTTP 500).'),
  >= 500 => ('server_error', 'Internal server error (HTTP $statusCode).'),
  429 => ('rate_limit', 'Rate limit exceeded (HTTP 429). Too many requests.'),
  404 => ('not_found', 'Resource not found (HTTP 404).'),
  403 => (
    'forbidden',
    'Forbidden access (HTTP 403). Insufficient permissions.',
  ),
  401 => (
    'unauthorized',
    'Unauthorized access (HTTP 401). Authentication required.',
  ),
  400 => (
    'bad_request',
    'Bad request (HTTP 400). The request was malformed or invalid.',
  ),
  _ => ('client_error', 'Client error (HTTP $statusCode).'),
};

// --- Errors ---

/// {@template http_bytes_exception}
/// Base class for all HTTP bytes client exceptions.
/// {@endtemplate}
@immutable
sealed class HttpBytesException implements Exception {
  /// {@macro http_bytes_exception}
  const HttpBytesException();

  /// HTTP status code. `0` when the request was not sent / no response.
  abstract final int statusCode;

  /// Machine-readable error code.
  abstract final String code;

  /// Human-readable detail.
  abstract final String message;

  /// The source error object.
  abstract final Object? error;

  /// Additional data (url, headers, …).
  abstract final Object? data;

  @override
  String toString() => message;
}

/// {@template http_bytes_exception_internal}
/// Internal (client-side) exception — empty body, closed client, or unknown
/// error. This is NOT an HTTP "client error (4xx)" — those are
/// [HttpBytesException$Request]. [statusCode] is 0 unless a partial response
/// was already seen.
/// {@endtemplate}
final class HttpBytesException$Internal extends HttpBytesException {
  /// {@macro http_bytes_exception_internal}
  const HttpBytesException$Internal({
    required this.code,
    required this.message,
    required this.statusCode,
    this.error,
    this.data,
  });

  @override
  final String code;

  @override
  final String message;

  @override
  final int statusCode;

  @override
  final Object? error;

  @override
  final Object? data;
}

/// {@template http_bytes_exception_network}
/// Network (transport) exception — no HTTP response (DNS/TCP/TLS/socket).
/// HTTP error *responses* are [HttpBytesException$Request] /
/// [HttpBytesException$Server] / [HttpBytesException$Authentication], not this.
/// {@endtemplate}
final class HttpBytesException$Network extends HttpBytesException {
  /// {@macro http_bytes_exception_network}
  const HttpBytesException$Network({
    required this.code,
    required this.message,
    required this.statusCode,
    this.error,
    this.data,
  });

  @override
  final String code;

  @override
  final String message;

  @override
  final int statusCode;

  @override
  final Object? error;

  @override
  final Object? data;
}

/// {@template http_bytes_exception_request}
/// Request exception — non-auth client-error status (4xx, e.g. 400/404/429).
/// The request itself is at fault and is not treated as a transient server fault.
/// {@endtemplate}
final class HttpBytesException$Request extends HttpBytesException {
  /// {@macro http_bytes_exception_request}
  const HttpBytesException$Request({
    required this.code,
    required this.message,
    required this.statusCode,
    this.error,
    this.data,
  });

  @override
  final String code;

  @override
  final String message;

  @override
  final int statusCode;

  @override
  final Object? error;

  @override
  final Object? data;
}

/// {@template http_bytes_exception_server}
/// Server exception — the server responded with a 5xx status (e.g. 500/502/503).
/// {@endtemplate}
final class HttpBytesException$Server extends HttpBytesException {
  /// {@macro http_bytes_exception_server}
  const HttpBytesException$Server({
    required this.code,
    required this.message,
    required this.statusCode,
    this.error,
    this.data,
  });

  @override
  final String code;

  @override
  final String message;

  @override
  final int statusCode;

  @override
  final Object? error;

  @override
  final Object? data;
}

/// {@template http_bytes_exception_authentication}
/// Authentication exception — 401 or 403 from the server.
/// {@endtemplate}
final class HttpBytesException$Authentication extends HttpBytesException {
  /// {@macro http_bytes_exception_authentication}
  const HttpBytesException$Authentication({
    required this.code,
    required this.message,
    required this.statusCode,
    this.error,
    this.data,
  });

  @override
  final String code;

  @override
  final String message;

  @override
  final int statusCode;

  @override
  final Object? error;

  @override
  final Object? data;
}

/// {@template http_bytes_exception_cancelled}
/// Cancellation exception — aborted via a [CancelToken].
/// {@endtemplate}
final class HttpBytesException$Cancelled extends HttpBytesException {
  /// {@macro http_bytes_exception_cancelled}
  const HttpBytesException$Cancelled({
    this.code = 'cancelled',
    this.message = 'Request was cancelled.',
    this.statusCode = 0,
    this.error,
    this.data,
  });

  @override
  final String code;

  @override
  final String message;

  @override
  final int statusCode;

  @override
  final Object? error;

  @override
  final Object? data;
}

/// {@template http_bytes_exception_timeout}
/// Client timeout exception — thrown when a connect or receive timeout fires.
/// {@endtemplate}
final class HttpBytesException$Timeout extends HttpBytesException
    implements TimeoutException {
  /// {@macro http_bytes_exception_timeout}
  const HttpBytesException$Timeout({
    required this.code,
    required this.message,
    required this.statusCode,
    required this.duration,
    this.error,
    this.data,
  });

  @override
  final String code;

  @override
  final String message;

  @override
  final int statusCode;

  @override
  final Object? error;

  @override
  final Object? data;

  /// The duration that was exceeded.
  @override
  final Duration? duration;
}
