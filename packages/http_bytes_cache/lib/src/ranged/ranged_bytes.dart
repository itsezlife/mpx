import 'dart:async';
import 'dart:typed_data';

import 'package:cancel_token/cancel_token.dart';
import 'package:http_bytes_cache/src/bytes_cache.dart';
import 'package:http_bytes_cache/src/http/byte_range.dart';
import 'package:http_bytes_cache/src/http/http_bytes_client.dart';
import 'package:http_bytes_cache/src/http/http_bytes_transfer.dart';
import 'package:http_bytes_cache/src/http/request_priority.dart';
import 'package:http_bytes_cache/src/ranged/byte_range_set.dart';
import 'package:meta/meta.dart';

/// Where a ranged resource comes from and how the store keeps it.
@immutable
final class RangedRequest {
  /// [cacheKey] is the resource's identity (media is keyed by content, never
  /// by a URL that may be signed or rotate); [url] is where its bytes are
  /// fetched now.
  const RangedRequest({
    required this.url,
    required this.cacheKey,
    this.headers,
    this.quota = BytesQuota.videoRanges,
  });

  /// Where to GET the bytes.
  final Uri url;

  /// Identity of the resource in the store.
  final BytesCacheKey cacheKey;

  /// Extra request headers (authorization and similar).
  final Map<String, String>? headers;

  /// The quota the resource counts against.
  final BytesQuota quota;
}

/// A change to the bytes a ranged resource holds.
@immutable
sealed class RangedEvent {
  const RangedEvent();
}

/// Bytes [range] were written to the sparse file and can be read now: the
/// "range landed" signal.
final class RangeLanded extends RangedEvent {
  /// [range] is closed.
  const RangeLanded(this.range);

  /// The bytes that landed.
  final ByteRange range;
}

/// Every span was dropped: the representation changed (another validator,
/// or a `200` to a range request). Readers forget what they knew was
/// present; [RangeLanded] events of the new representation follow.
final class RangesReset extends RangedEvent {
  /// The single reset event.
  const RangesReset();
}

/// How a ranged resource is split into parts, and how many of them run at
/// once.
///
/// An ask for missing bytes goes out as single-range GETs (parts) of at
/// most [partBytes]. A short ask is split down to [minPartBytes] so it still
/// runs several parts: a 512 KiB read-ahead goes out as four 128 KiB parts.
/// At most [perResource] parts of one resource run at once, beyond the part
/// at an ask's first missing byte, which never waits on this cap. The total
/// across resources is the client's ([HttpBytesClient.maxConcurrent]).
///
/// Parts in flight keep a high-latency link busy: one GET after another
/// leaves it idle for a round trip between them.
@immutable
final class RangedParts {
  /// Parts of [minPartBytes] to [partBytes], [perResource] at once per
  /// resource.
  const RangedParts({
    this.partBytes = 512 * 1024,
    this.minPartBytes = 128 * 1024,
    this.perResource = 4,
  }) : assert(partBytes > 0, 'partBytes must be > 0'),
       assert(minPartBytes > 0, 'minPartBytes must be > 0'),
       assert(perResource > 0, 'perResource must be > 0');

  /// Bytes one part asks for at most.
  final int partBytes;

  /// Bytes a part is split down to at least (capped at [partBytes]).
  final int minPartBytes;

  /// Parts of one resource in flight at once.
  final int perResource;

  /// The size of each part for an ask missing [missing] bytes: spread over
  /// [perResource] parts, between [minPartBytes] and [partBytes].
  int sizeFor(int missing) {
    final floor = minPartBytes < partBytes ? minPartBytes : partBytes;
    final spread = (missing + perResource - 1) ~/ perResource;
    return spread < floor ? floor : (spread > partBytes ? partBytes : spread);
  }
}

/// Fetches ranged resources into an [IRangedBytesStore].
///
/// One [RangedResource] per key: every [open] of a key shares its bytes, its
/// fetches and its events until the last handle closes. Missing bytes are
/// fetched in parts ([RangedParts]): single-range GETs through [client] (so
/// its middlewares, priorities and slots apply), several in flight at once,
/// each written to the sparse file at its offset as it arrives, in pieces of
/// at least [writeBytes], and announced as [RangeLanded]. Parts land in any
/// order; a reader waits for the bytes it asked for, wherever they come
/// from. An ask that runs to the end ([ByteRange.end] null) learns the
/// length from its first part, then goes on in parts.
///
/// The part at an ask's first missing byte goes out at the ask's priority;
/// the parts ahead of it one step lower, so bytes something reads now
/// overtake bytes read ahead in the client's queue.
///
/// When the client [HttpBytesClient.canTransfer] and the store keeps files,
/// each GET is a transfer: its body is written into the sparse file on the
/// client's worker isolate, and this isolate only records the spans that
/// landed. The bytes never enter it.
///
/// A `206` adds bytes. A `200` to a range GET means the server ignores ranges
/// or the representation changed: every span is dropped, the resource's
/// other parts stop, and the new body is kept as it streams. Without
/// `Accept-Ranges` the resource is read sequentially from then on. A
/// validator that differs from the stored one drops the spans as well; with
/// [HttpBytesConditionalMiddleware] in the client's chain, the GET carries
/// `If-Range` so the server answers the change at once.
///
/// Needs a store that [IRangedBytesStore.supportsRanges] (the VM store);
/// [isSupported] is false otherwise and [open] throws [UnsupportedError].
final class RangedBytes {
  /// Fetches into [store] through [client] (default: the shared client).
  RangedBytes({
    required IBytesStore store,
    HttpBytesClient? client,
    this.parts = const RangedParts(),
    this.writeBytes = 64 * 1024,
  }) : assert(writeBytes > 0, 'writeBytes must be > 0'),
       _store = store,
       _client = client;

  final IBytesStore _store;
  final HttpBytesClient? _client;

  /// How missing bytes are split and how many parts run at once.
  final RangedParts parts;

  /// Bytes buffered from the network before one write to the sparse file.
  final int writeBytes;

  final Map<BytesCacheKey, _RangedCore> _open = {};
  var _closed = false;

  HttpBytesClient get _http => _client ?? HttpBytesClient.shared();

  /// Whether the store keeps ranged resources.
  bool get isSupported => switch (_store) {
    final IRangedBytesStore ranged => ranged.supportsRanges,
    _ => false,
  };

  /// Opens the ranged resource of [request], sharing it with every other
  /// open handle of the same key. Close the handle when done.
  Future<RangedResource> open(RangedRequest request) async {
    if (_closed) throw StateError('RangedBytes is closed');
    final store = switch (_store) {
      final IRangedBytesStore ranged when ranged.supportsRanges => ranged,
      _ => throw UnsupportedError(
        'This store keeps no ranged resources (only the VM store does).',
      ),
    };
    final key = request.cacheKey;
    final core =
        (_open[key] ??= _RangedCore(
            owner: this,
            store: store,
            request: request,
          ))
          ..handles += 1
          ..request = request;
    try {
      await core.ready;
    } on Object {
      await core.releaseHandle();
      rethrow;
    }
    return RangedResource._(core);
  }

  /// Closes every open resource. Handles still held fail afterwards.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final cores = List.of(_open.values);
    _open.clear();
    for (final core in cores) {
      await core.shutDown();
    }
  }
}

/// A handle on one shared ranged resource ([RangedBytes.open]).
final class RangedResource {
  RangedResource._(this._core);

  final _RangedCore _core;
  var _closed = false;

  /// Identity of the resource.
  BytesCacheKey get key => _core.request.cacheKey;

  /// Path of the sparse payload file, held for as long as the resource is
  /// open (empty on a store that names no files).
  String get path => _core.lease.path;

  /// Bytes present now.
  ByteRangeSet get ranges => _core.state.ranges;

  /// Length of the representation, once a response has told it.
  int? get totalLength => _core.state.totalLength ?? _core.knownTotal;

  /// Whether the server ignores ranges, so bytes come in one sequential GET.
  bool get sequentialOnly => _core.sequentialOnly;

  /// [RangeLanded] and [RangesReset] as they happen, for every handle.
  Stream<RangedEvent> get events => _core.events.stream;

  /// Completes once every byte of [range] is present, fetching what is
  /// missing at [priority]. An open [range] runs to the end of the
  /// representation; bytes past the end count as present.
  ///
  /// Asks for bytes a running GET will bring join it instead of asking
  /// again. [cancelToken] stops this ask with [HttpBytesException$Cancelled];
  /// a GET nobody waits on any more is aborted (its bytes so far stay).
  Future<void> ensure(
    ByteRange range, {
    PriorityToken? priority,
    CancelToken? cancelToken,
  }) {
    _ensureOpen();
    return _core.ensure(range, priority: priority, cancelToken: cancelToken);
  }

  /// [ensure]s [range] (which must be closed, or open with a known length)
  /// and reads it from the sparse file.
  Future<Uint8List> read(
    ByteRange range, {
    PriorityToken? priority,
    CancelToken? cancelToken,
  }) async {
    await ensure(range, priority: priority, cancelToken: cancelToken);
    final total = totalLength;
    final end = range.end ?? total;
    if (end == null) throw StateError('Length of $key is unknown');
    final clipped = total != null && end > total ? total : end;
    if (clipped <= range.start) return Uint8List(0);
    final bytes = await _core.store.readRange(
      key,
      ByteRange(range.start, clipped),
    );
    if (bytes == null) {
      throw StateError('Bytes of $key went missing after they landed');
    }
    return bytes;
  }

  /// Prepares the resource to start playing before it is all cached: fetches
  /// the first [headBytes], then walks the progressive MP4's top-level boxes
  /// to its `moov` and makes sure all of it is present. When `moov` follows
  /// the media data, only the tail it sits in is fetched, never the middle.
  ///
  /// Returns where `moov` is, or null when the body is not progressive MP4
  /// (or has no `moov` in its first [maxBoxes] boxes); the head is held
  /// either way.
  Future<MoovLocation?> fastStart({
    int headBytes = 1024 * 1024,
    int maxBoxes = 64,
    PriorityToken? priority,
    CancelToken? cancelToken,
  }) async {
    Future<Uint8List> bytesAt(int start, int length) => read(
      ByteRange(start, start + length),
      priority: priority,
      cancelToken: cancelToken,
    );

    await ensure(
      ByteRange(0, headBytes),
      priority: priority,
      cancelToken: cancelToken,
    );
    var offset = 0;
    for (var i = 0; i < maxBoxes; i++) {
      final total = totalLength;
      if (total == null || offset + 8 > total) return null;
      final header = await bytesAt(offset, offset + 16 <= total ? 16 : 8);
      final box = _Mp4BoxHeader.parse(header, total - offset);
      if (box == null) return null;
      if (box.type == 'moov') {
        final end = offset + box.size;
        await ensure(
          ByteRange(offset, end),
          priority: priority,
          cancelToken: cancelToken,
        );
        return MoovLocation(offset, end, moovAtEnd: offset >= headBytes);
      }
      offset += box.size;
    }
    return null;
  }

  /// Gives this handle back; the last one stops fetches and releases the
  /// file for eviction. Idempotent.
  Future<void> close() {
    if (_closed) return Future<void>.value();
    _closed = true;
    return _core.releaseHandle();
  }

  void _ensureOpen() {
    if (_closed) throw StateError('RangedResource is closed');
  }
}

/// The shared state behind every handle of one key.
final class _RangedCore {
  _RangedCore({
    required this.owner,
    required this.store,
    required this.request,
  }) {
    ready = store
        .openRanged(request.cacheKey, quota: request.quota)
        .then((lease) => this.lease = lease);
  }

  final RangedBytes owner;
  final IRangedBytesStore store;
  RangedRequest request;
  late final Future<void> ready;
  late final FileLease lease;
  int handles = 0;
  var _shutDown = false;

  final StreamController<RangedEvent> events =
      StreamController<RangedEvent>.broadcast();
  final List<_Fetch> _fetches = [];

  bool sequentialOnly = false;

  /// A length learnt without writing (a `416`).
  int? knownTotal;

  BytesCacheKey get key => request.cacheKey;

  RangedState get state =>
      store.rangesOf(key) ?? const RangedState(ranges: ByteRangeSet.empty);

  Future<void> ensure(
    ByteRange want, {
    PriorityToken? priority,
    CancelToken? cancelToken,
  }) async {
    final ask = _Ask(priority?.priority ?? RequestPriority.visible);
    // One link for the whole ask, however many parts and landings it waits
    // through: a long-lived token must not keep every past wait alive.
    final wait = cancelToken == null ? null : CancelToken();
    final unlink = wait == null ? null : cancelToken!.link(wait);
    try {
      while (true) {
        _settle(ask);
        if (_shutDown) throw StateError('RangedResource is closed');
        if (cancelToken?.isCancelled ?? false) {
          throw HttpBytesException$Cancelled(
            error: CancelledException(cancelToken!.reason),
          );
        }
        final current = state;
        final total = current.totalLength ?? knownTotal;
        final end = switch ((want.end, total)) {
          (final e?, final t?) => e < t ? e : t,
          (final e?, null) => e,
          (null, final t?) => t,
          (null, null) => null,
        };
        if (end != null && want.start >= end) return;
        final int gapStart;
        if (end == null) {
          // Length unknown: the first part learns it.
          gapStart = current.ranges.contiguousFrom(want.start);
        } else {
          final gap = current.ranges.firstGap(want.start, end);
          if (gap == null) return;
          gapStart = gap.$1;
        }
        // Planned once, from what the ask misses when its end is known: the
        // parts of one ask keep their size as the gap closes.
        final size = end == null
            ? owner.parts.partBytes
            : ask.partBytes ??= owner.parts.sizeFor(end - gapStart);
        // The lead runs a whole part even past the ask's end (a reader
        // moving on finds the next bytes there); the parts ahead stay
        // inside the ask.
        final lead =
            _leadAt(gapStart) ??
            _start(gapStart, end: total, size: size, priority: ask.priority);
        ask.join(lead, ask.priority);
        final from = lead.range?.end;
        if (end != null && from != null) {
          _planAhead(ask, from: from, end: end, size: size);
        }
        // Wake on every landing and every part's end, not only the lead's:
        // a part behind a slow one lands, and the next one starts.
        final changed = _changed.future;
        if (wait == null) {
          await changed;
        } else {
          await Future.any([changed, wait.whenCancel]);
        }
      }
    } finally {
      unlink?.call();
      ask.leave(abortIdle: cancelToken?.isCancelled ?? false);
    }
  }

  /// Throws what ended a part [ask] waits on: its error, or a server that
  /// sent nothing where the part starts.
  void _settle(_Ask ask) {
    for (final fetch in ask.ended()) {
      if (fetch.superseded) continue;
      if (fetch.error case final error?) {
        Error.throwWithStackTrace(error, fetch.stackTrace!);
      }
      final start = fetch.start;
      if (fetch.landedBytes > 0 || start == null) continue;
      final after = state;
      final ended = switch (after.totalLength ?? knownTotal) {
        final t? => start >= t,
        null => false,
      };
      if (!ended && !after.ranges.covers(start, start + 1)) {
        throw HttpBytesException$Internal(
          code: 'range_not_served',
          message: 'The server did not send bytes at $start of $key.',
          statusCode: 0,
          data: <String, Object?>{'url': request.url.toString()},
        );
      }
    }
  }

  /// Completes on every landing and every part's end, then is replaced.
  Completer<void> _changed = Completer<void>();

  void notify() {
    final changed = _changed;
    _changed = Completer<void>();
    changed.complete();
  }

  /// A running GET an ask whose first missing byte is [offset] joins: one
  /// about to write it, or the whole body of a resource read sequentially.
  _Fetch? _leadAt(int offset) {
    for (final fetch in _fetches) {
      if (fetch.isStopping) continue;
      if (sequentialOnly ? fetch.range == null : fetch.joins(offset)) {
        return fetch;
      }
    }
    return null;
  }

  /// A running part that will write the byte at [offset], however far
  /// from its next byte.
  _Fetch? _bringing(int offset) {
    for (final fetch in _fetches) {
      if (!fetch.isStopping && fetch.brings(offset)) return fetch;
    }
    return null;
  }

  /// Starts the parts ahead of an ask's first one, from [from] to [end],
  /// while the resource has fewer than [RangedParts.perResource] in flight,
  /// joining the running parts on the way.
  void _planAhead(
    _Ask ask, {
    required int from,
    required int end,
    required int size,
  }) {
    final level = ask.priority.index > 0
        ? RequestPriority.values[ask.priority.index - 1]
        : ask.priority;
    var offset = from;
    while (offset < end && _fetches.length < owner.parts.perResource) {
      final gap = state.ranges.firstGap(offset, end);
      if (gap == null) return;
      offset = gap.$1;
      final running = _bringing(offset);
      if (running != null) {
        ask.join(running, level);
        final next = running.range?.end;
        if (next == null) return;
        offset = next;
        continue;
      }
      final part = _start(offset, end: gap.$2, size: size, priority: level);
      ask.join(part, level);
      offset = part.range!.end!;
    }
  }

  /// Starts a GET from [start]: a part of at most [size] bytes, stopping at
  /// [end] and at the next byte held, or the whole body when the resource is
  /// read sequentially.
  _Fetch _start(
    int start, {
    required int? end,
    required int size,
    required RequestPriority priority,
  }) {
    final ByteRange? range;
    if (sequentialOnly) {
      range = null;
    } else {
      var stop = start + size;
      final next = state.ranges.nextPresentFrom(start);
      if (next != null && next < stop) stop = next;
      if (end != null && end < stop) stop = end;
      range = ByteRange(start, stop);
    }
    final fetch = _Fetch(
      core: this,
      range: range,
      priority: PriorityToken(priority),
    );
    _fetches.add(fetch);
    unawaited(fetch.run());
    return fetch;
  }

  /// Stops every part but [keep]: a `200` replaced the representation, and
  /// their bytes are the old one's or come again in [keep]'s body.
  void supersedeAllBut(_Fetch keep) {
    for (final fetch in List.of(_fetches)) {
      if (identical(fetch, keep) || fetch.isDone) continue;
      fetch
        ..superseded = true
        ..abort();
    }
  }

  /// [fetch] ended: forget it and wake the asks.
  void ended(_Fetch fetch) {
    _fetches.remove(fetch);
    notify();
  }

  /// Writes [bytes] at [offset] and announces them, after a reset when the
  /// write dropped spans the resource had.
  Future<void> land(
    int offset,
    Uint8List bytes, {
    required HttpCacheMeta? validator,
    required int? totalLength,
  }) async {
    final before = state.ranges;
    final after = await store.writeRange(
      key,
      offset,
      bytes,
      validator: validator,
      totalLength: totalLength,
      quota: request.quota,
    );
    if (!_keepsAll(before, after.ranges)) _emit(const RangesReset());
    if (bytes.isNotEmpty) {
      _emit(RangeLanded(ByteRange(offset, offset + bytes.length)));
    }
  }

  /// Records `[start, end)`, written into the sparse file by a transfer, and
  /// announces it, after a reset when the record dropped spans the resource
  /// had.
  Future<void> record(
    int start,
    int end, {
    required HttpCacheMeta? validator,
    required int? totalLength,
  }) async {
    final before = state.ranges;
    final after = await store.recordRange(
      key,
      start,
      end - start,
      validator: validator,
      totalLength: totalLength,
      quota: request.quota,
    );
    if (!_keepsAll(before, after.ranges)) _emit(const RangesReset());
    if (end > start) _emit(RangeLanded(ByteRange(start, end)));
  }

  Future<void> reset({
    required HttpCacheMeta? validator,
    required int? totalLength,
  }) async {
    await store.resetRanges(
      key,
      validator: validator,
      totalLength: totalLength,
      quota: request.quota,
    );
    _emit(const RangesReset());
  }

  void _emit(RangedEvent event) {
    if (!events.isClosed) events.add(event);
  }

  static bool _keepsAll(ByteRangeSet before, ByteRangeSet after) {
    for (final (start, end) in before.spans) {
      if (!after.covers(start, end)) return false;
    }
    return true;
  }

  Future<void> releaseHandle() async {
    handles -= 1;
    if (handles > 0 || _shutDown) return;
    if (identical(owner._open[key], this)) owner._open.remove(key);
    await shutDown();
  }

  Future<void> shutDown() async {
    if (_shutDown) return;
    _shutDown = true;
    for (final fetch in List.of(_fetches)) {
      fetch.abort();
    }
    await events.close();
    try {
      await ready;
      await lease.release();
    } on Object {
      // Never opened: nothing to release.
    }
  }
}

/// What one ensure waits on: the parts it started or joined.
final class _Ask {
  _Ask(this.priority);

  final RequestPriority priority;
  final Set<_Fetch> _joined = {};

  /// The size of this ask's parts, once its end is known.
  int? partBytes;

  /// Counts this ask on [fetch] once, raising it to [level].
  void join(_Fetch fetch, RequestPriority level) {
    fetch.raise(level);
    if (_joined.add(fetch)) fetch.interest++;
  }

  /// The joined parts that ended since the last call; they are left.
  List<_Fetch> ended() {
    final done = [
      for (final fetch in _joined)
        if (fetch.isDone) fetch,
    ];
    for (final fetch in done) {
      _joined.remove(fetch);
      fetch.interest--;
    }
    return done;
  }

  /// Leaves every joined part. A cancelled ask ([abortIdle]) aborts the
  /// parts nobody else waits on; their landed bytes stay.
  void leave({required bool abortIdle}) {
    for (final fetch in _joined) {
      fetch.interest--;
      if (abortIdle && fetch.interest == 0 && !fetch.isDone) fetch.abort();
    }
    _joined.clear();
  }
}

/// One GET bringing bytes into a ranged resource: a part (a range GET), or
/// the whole body when the resource is read sequentially.
final class _Fetch {
  _Fetch({required this.core, required this.range, required this.priority})
    : start = range?.start,
      cursor = range?.start ?? 0;

  final _RangedCore core;

  /// The range asked for; null for a whole-body GET.
  ByteRange? range;

  /// The first byte asked for; null for a whole-body GET.
  final int? start;
  final PriorityToken priority;
  final CancelToken _token = CancelToken();

  /// Asks waiting on this GET.
  int interest = 0;

  bool isDone = false;

  /// What ended the GET before its body did.
  Object? error;
  StackTrace? stackTrace;

  /// Stopped because another part's `200` replaced the representation: it
  /// ends quietly and records nothing more.
  bool superseded = false;

  /// Next byte this GET will write.
  int cursor;

  /// Bytes this GET wrote so far.
  int landedBytes = 0;

  /// How far ahead of a running GET's next byte an ask still joins it. A
  /// byte further on gets a GET of its own: an index at the end of a file
  /// is fetched now, not after the body that comes before it.
  static const int joinWindow = 32 * 1024;

  /// Whether an ask whose first missing byte is [offset] waits on this GET.
  bool joins(int offset) => brings(offset) && offset - cursor < joinWindow;

  /// Whether this GET will write the byte at [offset].
  bool brings(int offset) =>
      cursor <= offset &&
      switch (range?.end) {
        final end? => offset < end,
        null => true,
      };

  void raise(RequestPriority level) {
    if (level.isAbove(priority.priority)) priority.priority = level;
  }

  void abort() => _token.cancel();

  /// Ended, or on its way out: an ask starts a GET of its own instead.
  bool get isStopping => isDone || _token.isCancelled;

  Future<void> run() async {
    try {
      await _transfer();
    } on Object catch (error, stackTrace) {
      if (!superseded) {
        this.error = error;
        this.stackTrace = stackTrace;
      }
    }
    isDone = true;
    core.ended(this);
  }

  void _landed(int end, int bytes) {
    cursor = end;
    landedBytes += bytes;
    core.notify();
  }

  Future<void> _transfer() async {
    final stored = core.state;
    final context = HttpBytesContext.empty();
    if (stored.validator?.etag case final etag?) context.etag = etag;
    final asked = range;
    final client = core.owner._http;
    // Off this isolate when the client can and the store names the file the
    // worker writes into.
    final offIsolate = client.canTransfer && core.lease.path.isNotEmpty;
    final HttpBytesResponse response;
    HttpBytesTransfer? transfer;
    try {
      if (offIsolate) {
        transfer = await client.transfer(
          core.request.url,
          headers: core.request.headers,
          range: asked,
          cancelToken: _token,
          priority: priority,
          context: context,
        );
        response = transfer.head;
      } else {
        response = await client.stream(
          core.request.url,
          headers: core.request.headers,
          range: asked,
          cancelToken: _token,
          priority: priority,
          context: context,
        );
      }
    } on HttpBytesException$Request catch (error) {
      if (error.statusCode != 416) rethrow;
      // Past the end: the answer names the length, so the ask is settled.
      core.knownTotal = switch (error.data) {
        {'headers': final Map<String, String> headers} =>
          ContentRange.unsatisfiedLength(headers['content-range']),
        _ => null,
      };
      return;
    }

    if (superseded) {
      transfer?.cancel();
      return;
    }
    final validator = _validatorOf(response.headers);
    int offset;
    final int? total;
    switch (response.statusCode) {
      case 206:
        final content = response.contentRange;
        if (content == null) {
          transfer?.cancel();
          await response.stream.drain<void>();
          throw HttpBytesException$Internal(
            code: 'bad_content_range',
            message: 'A 206 without a usable Content-Range.',
            statusCode: 206,
            data: <String, Object?>{'url': core.request.url.toString()},
          );
        }
        offset = content.start;
        total = content.totalLength;
      default:
        // The whole representation. To a range GET this means the server
        // ignores ranges or the representation changed: drop every span and
        // keep the new body. Without Accept-Ranges, read sequentially.
        offset = 0;
        total = response.totalLength;
        if (!response.acceptsRanges) core.sequentialOnly = true;
        if (asked != null) core.supersedeAllBut(this);
        if (asked != null || !_sameRepresentation(stored, validator)) {
          await core.reset(validator: validator, totalLength: total);
        }
        range = null;
    }
    cursor = offset;

    if (transfer != null) {
      await transfer.writeTo(
        core.lease.path,
        offset: offset,
        onLanded: (start, end) async {
          if (superseded) return;
          await core.record(
            start,
            end,
            validator: validator,
            totalLength: total,
          );
          _landed(end, end - start);
        },
      );
      return;
    }

    final pending = BytesBuilder(copy: false);
    Future<void> flush() async {
      if (pending.isEmpty || superseded) return;
      final bytes = pending.takeBytes();
      await core.land(offset, bytes, validator: validator, totalLength: total);
      offset += bytes.length;
      _landed(offset, bytes.length);
    }

    await for (final chunk in response.stream) {
      pending.add(chunk);
      if (pending.length >= core.owner.writeBytes) await flush();
    }
    await flush();
  }

  static bool _sameRepresentation(RangedState stored, HttpCacheMeta? next) {
    final a = stored.validator;
    if (a?.etag != null || next?.etag != null) return a?.etag == next?.etag;
    return a?.lastModified == next?.lastModified;
  }

  static HttpCacheMeta? _validatorOf(Map<String, String> headers) {
    final etag = headers['etag'];
    final lastModified = headers['last-modified'];
    if (etag == null && lastModified == null) return null;
    return HttpCacheMeta(etag: etag, lastModified: lastModified);
  }
}

/// Where a progressive MP4 keeps its `moov` box ([RangedResource.fastStart]).
@immutable
final class MoovLocation {
  /// `moov` spans `[moovStart, moovEnd)`.
  const MoovLocation(this.moovStart, this.moovEnd, {required this.moovAtEnd});

  /// Offset of the box header.
  final int moovStart;

  /// One past the box's last byte.
  final int moovEnd;

  /// Whether `moov` lies past the head, after the media data: playback
  /// needs the tail before it can start.
  final bool moovAtEnd;
}

/// A top-level ISO base media file box header: size (with the 64-bit and
/// to-the-end forms resolved) and four-character type.
@immutable
final class _Mp4BoxHeader {
  /// A box of [size] bytes, header included.
  const _Mp4BoxHeader(this.type, this.size);

  /// Four-character type (`ftyp`, `moov`, `mdat`, …).
  final String type;

  /// Box size in bytes, header included.
  final int size;

  /// Parses the header at the start of [bytes] (8 bytes, or 16 for a 64-bit
  /// size); [remaining] is the bytes left in the file from the box, which a
  /// size of 0 ("to the end") takes. Null when the bytes are not a box
  /// header: too short, a size smaller than its header or past [remaining],
  /// or a type that is not four printable characters.
  static _Mp4BoxHeader? parse(Uint8List bytes, int remaining) {
    if (bytes.length < 8) return null;
    final data = ByteData.sublistView(bytes);
    for (var i = 4; i < 8; i++) {
      if (bytes[i] < 0x20 || bytes[i] > 0x7e) return null;
    }
    final type = String.fromCharCodes(bytes, 4, 8);
    var size = data.getUint32(0);
    var header = 8;
    if (size == 1) {
      if (bytes.length < 16) return null;
      size = data.getUint64(8);
      header = 16;
    } else if (size == 0) {
      size = remaining;
    }
    if (size < header || size > remaining) return null;
    return _Mp4BoxHeader(type, size);
  }
}
