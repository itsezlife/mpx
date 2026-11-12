// ignore_for_file: one_member_abstracts

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http_bytes_cache/src/bytes_diagnostics.dart';
import 'package:http_bytes_cache/src/environment_specific/cache_open.dart' as environment_specific;
import 'package:meta/meta.dart';

/// Cache identity for remote bytes (disk / durable store / PageStorage).
///
/// Filename-safe string: host + last path segment + a short fingerprint of the
/// [Uri.base.resolve] canonical URL and canonical headers (length-prefixed
/// material — not a `url|headers` join). Shared with [HttpBytesClient]
/// coalesce via [value]. Without the fingerprint, two URLs that share a
/// basename would collide on disk.
@immutable
final class BytesCacheKey {
  /// Wraps an already-safe [value] (tests, restore from storage).
  const BytesCacheKey(this.value);

  /// Derives [value] from [url] and optional [headers].
  ///
  /// [url] is resolved with [Uri.base.resolve] before host/basename extraction
  /// and fingerprinting, so a relative path and its absolute form against the
  /// same base produce one key — matching the URI [BytesResolver] GETs.
  ///
  /// Header keys are lowercased and sorted before hashing so casing and map
  /// iteration order do not change identity (parity with
  /// [HttpBytesClient] coalesce). Conditional request headers
  /// (`If-None-Match`, `If-Modified-Since`, and RFC equivalents) are
  /// **excluded** from identity so local validators stay wire-only and do not
  /// fragment coalesce or durable keys. Other headers (e.g. `Authorization`)
  /// still participate. Values stay as given. Fingerprint material is a
  /// length-prefixed encoding of URL + canonical headers so a `|` (or any
  /// other character) inside the URL or a header value cannot forge another
  /// (url, headers) pair.
  ///
  /// Distinct URLs that share a basename still produce distinct keys via the
  /// fingerprint. [value] is capped at [_maxValueLength] so hosts with long
  /// path segments stay safe as filenames and web store keys (basename
  /// truncated; fingerprint and host still distinguish collisions).
  factory BytesCacheKey.fromUrl(
    String url, {
    Map<String, String>? headers,
  }) {
    final canonicalUrl = Uri.base.resolve(url).toString();
    final uri = Uri.tryParse(canonicalUrl);
    final host = switch (uri?.host) {
      final h? when h.isNotEmpty => h.replaceAll('.', '_'),
      _ => 'unknown',
    };
    final pathSeg = switch (uri?.pathSegments) {
      final segments? when segments.isNotEmpty => segments.last,
      _ => 'asset',
    };
    var safeName = pathSeg.replaceAll(RegExp('[^a-zA-Z0-9._-]'), '_').replaceAll('..', '_');
    final fingerprint = sha1.convert(_fingerprintMaterial(canonicalUrl, headers)).toString().substring(0, 12);
    // Reserve room for host + '_' + '_' + 12-char fingerprint.
    final maxNameLen = (_maxValueLength - host.length - fingerprint.length - 2).clamp(8, _maxBasenameLength);
    if (safeName.length > maxNameLen) {
      safeName = safeName.substring(0, maxNameLen);
    }
    var value = '${host}_${safeName}_$fingerprint';
    if (value.length > _maxValueLength) {
      // Extreme host length: keep trailing fingerprint; truncate from the front of the stem.
      value = value.substring(value.length - _maxValueLength);
    }
    return BytesCacheKey(value);
  }

  /// Filename-safe identity string.
  final String value;

  /// Soft ceiling for filesystem and typical web cache key limits.
  static const int _maxValueLength = 180;

  /// Cap on the basename segment before host/fingerprint are applied.
  static const int _maxBasenameLength = 64;

  /// HTTP conditional request headers that never participate in identity.
  ///
  /// They are set for revalidation on the wire only. Folding them into
  /// [fromUrl] / coalesce would split flights that share the same representation
  /// (Authorization and friends still participate).
  static const Set<String> _conditionalRequestHeaders = {
    'if-match',
    'if-none-match',
    'if-modified-since',
    'if-unmodified-since',
    'if-range',
  };

  /// Lowercase keys, last-wins on case duplicates, then sorted `k=v` join.
  ///
  /// Skips [_conditionalRequestHeaders]. Shared with [HttpBytesClient] coalesce
  /// so header casing and map order cannot split cache identity from in-flight
  /// GET dedupe, while validators stay wire-only.
  static String canonicalHeaders(Map<String, String>? headers) {
    if (headers == null || headers.isEmpty) return '';
    final normalized = <String, String>{
      for (final MapEntry(:key, :value) in headers.entries)
        if (!_conditionalRequestHeaders.contains(key.toLowerCase())) key.toLowerCase(): value,
    };
    if (normalized.isEmpty) return '';
    final keys = normalized.keys.toList()..sort();
    return keys.map((k) => '$k=${normalized[k]}').join('&');
  }

  /// Length-prefixed UTF-8 of canonical URL then canonical headers.
  ///
  /// Without length prefixes, a delimiter join such as `url|headers` lets a
  /// URL that embeds `|…` forge the same fingerprint bytes as a clean URL plus
  /// those headers (or a header value that embeds further `|` fields).
  static List<int> _fingerprintMaterial(String canonicalUrl, Map<String, String>? headers) {
    final urlBytes = const Utf8Encoder().convert(canonicalUrl);
    final headerBytes = const Utf8Encoder().convert(canonicalHeaders(headers));
    return <int>[
      ..._u32be(urlBytes.length),
      ...urlBytes,
      ..._u32be(headerBytes.length),
      ...headerBytes,
    ];
  }

  static List<int> _u32be(int length) => <int>[
    (length >> 24) & 0xff,
    (length >> 16) & 0xff,
    (length >> 8) & 0xff,
    length & 0xff,
  ];

  @override
  bool operator ==(Object other) => identical(this, other) || other is BytesCacheKey && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'BytesCacheKey($value)';
}

/// How long / how much an [IBytesCache] keeps entries.
///
/// TTL is checked on [IBytesCache.read]. Capacity is trimmed on
/// [IBytesCache.write] and [IBytesCache.prune]. There is no
/// background timer: without those calls, entries stay until the host deletes
/// them.
@immutable
sealed class BytesRetention {
  const BytesRetention();

  /// No automatic eviction (still removable via [IBytesCache.evict]).
  const factory BytesRetention.unlimited() = BytesRetentionUnlimited;

  /// Drop when [BytesRecord.writtenAt] is older than [maxAge].
  const factory BytesRetention.maxAge(Duration maxAge) = BytesRetentionMaxAge;

  /// Keep at most [maxEntries] (LRU by last access).
  ///
  /// [maxEntries] must be positive — a zero or negative cap is nonsense
  /// retention that would either retain nothing useful or never trim.
  const factory BytesRetention.maxEntries(int maxEntries) = BytesRetentionMaxEntries;

  /// Keep total payload size at or under [maxBytes] (LRU by last access).
  ///
  /// [maxBytes] must be positive — a non-positive byte budget cannot describe
  /// a usable capacity policy.
  const factory BytesRetention.maxBytes(int maxBytes) = BytesRetentionMaxBytes;

  /// Combine optional TTL and capacity limits.
  ///
  /// Null fields are ignored. Use this when you need more than one constraint.
  /// When set, [maxEntries] and [maxBytes] must be positive (same invariant as
  /// the dedicated factories).
  const factory BytesRetention.compound({
    Duration? maxAge,
    int? maxEntries,
    int? maxBytes,
  }) = BytesRetentionCompound;

  /// Default used by [BytesCache.open].
  ///
  /// Caps age (14 days), entry count (500), and total payload size (50 MiB).
  /// Entry count alone would let a few large assets fill the device; the byte
  /// budget bounds that without needing a background eviction timer.
  static const BytesRetention standard = BytesRetentionCompound(
    maxAge: Duration(days: 14),
    maxEntries: 500,
    maxBytes: 50 * 1024 * 1024,
  );

  /// Flattened view of this policy for implementers.
  ({Duration? maxAge, int? maxEntries, int? maxBytes}) get limits => switch (this) {
    BytesRetentionUnlimited() => (
      maxAge: null,
      maxEntries: null,
      maxBytes: null,
    ),
    BytesRetentionMaxAge(:final maxAge) => (
      maxAge: maxAge,
      maxEntries: null,
      maxBytes: null,
    ),
    BytesRetentionMaxEntries(:final maxEntries) => (
      maxAge: null,
      maxEntries: maxEntries,
      maxBytes: null,
    ),
    BytesRetentionMaxBytes(:final maxBytes) => (
      maxAge: null,
      maxEntries: null,
      maxBytes: maxBytes,
    ),
    BytesRetentionCompound(
      :final maxAge,
      :final maxEntries,
      :final maxBytes,
    ) =>
      (maxAge: maxAge, maxEntries: maxEntries, maxBytes: maxBytes),
  };
}

/// Variant of [BytesRetention.unlimited].
@immutable
final class BytesRetentionUnlimited extends BytesRetention {
  /// See [BytesRetention.unlimited].
  const BytesRetentionUnlimited();
}

/// Variant of [BytesRetention.maxAge].
@immutable
final class BytesRetentionMaxAge extends BytesRetention {
  /// See [BytesRetention.maxAge].
  const BytesRetentionMaxAge(this.maxAge);

  /// Maximum age since [BytesRecord.writtenAt].
  final Duration maxAge;
}

/// Variant of [BytesRetention.maxEntries].
@immutable
final class BytesRetentionMaxEntries extends BytesRetention {
  /// See [BytesRetention.maxEntries].
  const BytesRetentionMaxEntries(this.maxEntries) : assert(maxEntries > 0, 'maxEntries must be > 0');

  /// Maximum number of keys retained.
  final int maxEntries;
}

/// Variant of [BytesRetention.maxBytes].
@immutable
final class BytesRetentionMaxBytes extends BytesRetention {
  /// See [BytesRetention.maxBytes].
  const BytesRetentionMaxBytes(this.maxBytes) : assert(maxBytes > 0, 'maxBytes must be > 0');

  /// Maximum sum of [BytesRecord.byteLength] across entries.
  final int maxBytes;
}

/// Variant of [BytesRetention.compound].
@immutable
final class BytesRetentionCompound extends BytesRetention {
  /// See [BytesRetention.compound].
  const BytesRetentionCompound({
    this.maxAge,
    this.maxEntries,
    this.maxBytes,
  }) : assert(maxEntries == null || maxEntries > 0, 'maxEntries must be > 0 when set'),
       assert(maxBytes == null || maxBytes > 0, 'maxBytes must be > 0 when set');

  /// Optional TTL since write.
  final Duration? maxAge;

  /// Optional max key count.
  final int? maxEntries;

  /// Optional max total payload bytes.
  final int? maxBytes;
}

/// Keys removed and bytes freed by [IBytesCache.prune].
@immutable
final class BytesPruneReport {
  /// Snapshot of one prune pass.
  const BytesPruneReport({
    required this.evictedKeys,
    required this.freedBytes,
  });

  /// Keys deleted in this prune (order is implementation-defined).
  final List<BytesCacheKey> evictedKeys;

  /// Sum of [BytesRecord.byteLength] for those keys.
  final int freedBytes;
}

/// HTTP validators and freshness for one cached body.
///
/// Separate from [BytesRetention] and from [BytesRecord.writtenAt] /
/// [BytesRecord.accessedAt]. Retention evicts by age and capacity. The
/// resolve ladder uses this row for ETag / Last-Modified / Cache-Control
/// decisions via [HttpCacheFreshness].
///
/// Every field is optional. A row with all nulls (or a null
/// [BytesRecord.httpCacheMeta]) is a pre-ETag entry, not a decode error.
/// The durable index codec keeps these fields additive on `v:1`.
/// [BytesCacheKey] never hashes them.
@immutable
final class HttpCacheMeta {
  /// All fields default to null.
  const HttpCacheMeta({
    this.etag,
    this.lastModified,
    this.date,
    this.expires,
    this.cacheControl,
    this.age,
    this.lastValidatedAt,
  });

  /// `ETag` response value. Keeps surrounding quotes when the origin sent them.
  final String? etag;

  /// Raw `Last-Modified` header string.
  final String? lastModified;

  /// Parsed `Date` header, when the store recorded one.
  final DateTime? date;

  /// Parsed `Expires` header, when the store recorded one.
  final DateTime? expires;

  /// Raw `Cache-Control` string, or a lightly normalized copy of it.
  final String? cacheControl;

  /// `Age` header as a duration, when known.
  final Duration? age;

  /// Wall time of the last successful confirm: a 200 write-through or a 304.
  final DateTime? lastValidatedAt;

  /// True when every field is null. Encoders skip writing an empty `h` object.
  bool get isEmpty =>
      etag == null &&
      lastModified == null &&
      date == null &&
      expires == null &&
      cacheControl == null &&
      age == null &&
      lastValidatedAt == null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HttpCacheMeta &&
          other.etag == etag &&
          other.lastModified == lastModified &&
          other.date == date &&
          other.expires == expires &&
          other.cacheControl == cacheControl &&
          other.age == age &&
          other.lastValidatedAt == lastValidatedAt;

  @override
  int get hashCode => Object.hash(
    etag,
    lastModified,
    date,
    expires,
    cacheControl,
    age,
    lastValidatedAt,
  );
}

/// Bytes plus retention timestamps and optional [HttpCacheMeta].
///
/// [IBytesCache.read] still returns [Uint8List]?. Call
/// [IBytesRichCache.readRich], or run a middleware read through
/// `execute`, when you need the meta beside the body.
@immutable
final class BytesRichHit {
  /// [bytes] must be non-empty. Empty rows are scrubbed to a miss before this
  /// type is built.
  const BytesRichHit({
    required this.bytes,
    this.writtenAt,
    this.accessedAt,
    this.httpCacheMeta,
  });

  /// Payload. Never empty on a successful hit.
  final Uint8List bytes;

  /// Last write time when the store tracked it.
  final DateTime? writtenAt;

  /// Soft LRU access time when the store tracked it.
  final DateTime? accessedAt;

  /// Validators / freshness. Null when the row never stored any, including
  /// older durable documents that predate these fields.
  final HttpCacheMeta? httpCacheMeta;
}

/// Optional rich-read half for stores that keep meta beside bytes.
///
/// [MemoryBytesCache] and [IndexedBytesCache] implement this.
/// Middleware terminals call [readRich] when the inner store implements it.
/// Hosts that only call [IBytesCache.read] never see this type.
abstract interface class IBytesRichCache {
  /// Same miss, TTL, and empty-scrub rules as [IBytesCache.read], plus
  /// timestamps and [HttpCacheMeta] when present.
  Future<BytesRichHit?> readRich(BytesCacheKey key);
}

/// Metadata for one stored entry: timestamps, size, optional HTTP cache meta.
@immutable
final class BytesRecord {
  /// Builds a record for [key].
  const BytesRecord({
    required this.key,
    required this.writtenAt,
    required this.accessedAt,
    required this.byteLength,
    this.httpCacheMeta,
  });

  /// Entry identity.
  final BytesCacheKey key;

  /// When the payload was last written (UTC preferred).
  final DateTime writtenAt;

  /// Last access time used for LRU. Soft-updated by [IndexedBytesCache].
  final DateTime accessedAt;

  /// Payload length in bytes (used for [BytesRetention.maxBytes]).
  final int byteLength;

  /// HTTP validators / freshness for this body, or null for a pre-ETag row.
  ///
  /// Not part of [BytesCacheKey]. [BytesRetention] still looks only at
  /// [writtenAt], [accessedAt], and [byteLength].
  final HttpCacheMeta? httpCacheMeta;

  /// Copy with selected fields replaced.
  BytesRecord copyWith({
    DateTime? writtenAt,
    DateTime? accessedAt,
    int? byteLength,
    HttpCacheMeta? httpCacheMeta,
  }) => BytesRecord(
    key: key,
    writtenAt: writtenAt ?? this.writtenAt,
    accessedAt: accessedAt ?? this.accessedAt,
    byteLength: byteLength ?? this.byteLength,
    httpCacheMeta: httpCacheMeta ?? this.httpCacheMeta,
  );
}

/// Metadata half of [IndexedBytesCache].
///
/// Kept separate from [IBytesBlobStore] so prune and LRU can scan records
/// without reading every payload. After [IndexedBytesCache] opens, the
/// hot path treats this as a **RAM mirror**: [get] / [put] / [delete] /
/// [values] must not hit durable meta IO. Durable backends persist only in
/// [commit], once per exclusive mutate epoch (after soft-LRU flush and
/// in-memory puts/deletes/trim), never once per key during a multi-key flush.
///
/// Memory-only fakes may no-op [commit]. Platform adapters (file snapshot on
/// VM, Cache API document on web) load into RAM on open and rewrite the
/// durable document only from [commit].
abstract interface class IBytesIndex {
  /// Returns the record for [key], or `null` if missing. RAM mirror only.
  Future<BytesRecord?> get(BytesCacheKey key);

  /// Inserts or replaces the record for [record.key] in the RAM mirror.
  ///
  /// Does not persist. [IndexedBytesCache] calls [commit] once after the
  /// mutate epoch finishes mutating the mirror.
  Future<void> put(BytesRecord record);

  /// Removes the record for [key] from the RAM mirror if present.
  ///
  /// Does not persist. See [put].
  Future<void> delete(BytesCacheKey key);

  /// All records in the RAM mirror (used by prune / capacity trim).
  Future<Iterable<BytesRecord>> values();

  /// Persists the current RAM mirror once (atomic snapshot or txn).
  ///
  /// Called at most once per exclusive mutate epoch. No-op when there is no
  /// durable backend.
  Future<void> commit();
}

/// Payload half of [IndexedBytesCache].
///
/// Bytes only. Retention and timestamps live on [IBytesIndex].
abstract interface class IBytesBlobStore {
  /// Returns payload bytes for [key], or `null` if missing.
  ///
  /// [knownByteLength] is an optional hint from the RAM index row already
  /// probed by [IndexedBytesCache]. Web size-routed stores use it to skip
  /// a guaranteed Cache API miss when the body lives in OPFS; other backends
  /// ignore it. Callers that do not know the length omit the argument and get
  /// the store's default probe order.
  Future<Uint8List?> read(BytesCacheKey key, {int? knownByteLength});

  /// Writes or replaces payload bytes for [key].
  Future<void> write(BytesCacheKey key, Uint8List bytes);

  /// Removes payload bytes for [key] if present.
  Future<void> delete(BytesCacheKey key);
}

/// Store for remote bytes (any payload format).
///
/// Callers and widgets talk to this type. They should not know about durable
/// backends, files, or [IBytesIndex] / [IBytesBlobStore].
abstract interface class IBytesCache {
  /// Returns cached bytes for [key], or `null` on miss / expired TTL.
  Future<Uint8List?> read(BytesCacheKey key);

  /// Stores [bytes] under [key] and applies capacity retention.
  ///
  /// Empty [bytes] are not retained: the write is treated as eviction of [key]
  /// when present. An empty durable row would still count toward
  /// [BytesRetention.maxEntries] while never painting, so hosts must not
  /// be able to stick zero-length capacity waste through this API.
  ///
  /// Pass [httpCacheMeta] when the store should keep validators next to the
  /// body ([MemoryBytesCache], [IndexedBytesCache]). Null (the
  /// default) clears any previous meta for [key]. That matches a bytes-only
  /// replace: the old ETag belonged to the old body. [BytesCacheKey] is
  /// unchanged either way.
  Future<void> write(
    BytesCacheKey key,
    Uint8List bytes, {
    HttpCacheMeta? httpCacheMeta,
  });

  /// Deletes one key if present (index and payload when composed).
  Future<void> evict(BytesCacheKey key);

  /// Runs TTL and capacity eviction. Returns what was removed.
  Future<BytesPruneReport> prune();

  /// Releases owned resources. Idempotent.
  ///
  /// [MemoryBytesCache] and [NoOpBytesCache] stay usable after close
  /// so tearDown can call this uniformly. [IndexedBytesCache] and durable
  /// compositions reject later ops with [StateError] (same idea as
  /// [HttpBytesClient.close]).
  Future<void> close();
}

/// [IBytesCache] that keeps metadata and payloads in separate stores.
///
/// ## Hot path
///
/// After open, [IBytesIndex] is a RAM mirror. Pure [read] hits (and soft
/// misses) run **concurrently**. They do not take the exclusive gate and do
/// not call [IBytesIndex.commit]. Soft LRU only notes access in
/// [_pendingAccess]; durable meta stays quiet on paint.
///
/// ## Mutate epoch
///
/// The following operations share a single, exclusive domain (all readers
/// complete first):
/// - [write]
/// - [evict]
/// - [prune]
/// - TTL or orphan-index deletes triggered during [read]
/// - [reclaimOrphans]
/// - [close]
///
/// Within a mutate epoch, the following steps are performed:
///  1. Snapshot the RAM mirror (last-good meta for rollback).
///  2. Flush soft access into the RAM mirror.
///  3. Apply puts, deletes, and capacity trim in RAM (including blob I/O).
///  4. Call [IBytesIndex.commit] **once**.
///  5. For [prune] (and explicit [reclaimOrphans]), run orphan blob reclamation.
///
/// Without that single-commit rule, a soft-LRU flush that touches N keys would
/// rewrite the durable index N times. Without the shared exclusive domain,
/// orphan reclaim can delete a blob mid-write.
///
/// ## Commit failure
///
/// If [IBytesIndex.commit] throws after the RAM (and possibly blob) half
/// has already mutated, the brain rolls the RAM mirror back to the pre-epoch
/// snapshot and rethrows. Later in-process [read]s must not treat the
/// optimistic put as a durable hit. Blob halves are not rolled back. A failed
/// write may leave an orphan blob. A failed commit after trim, evict, or TTL
/// may put index rows back whose payloads were already deleted; the next read
/// heals those as index-without-blob, and those victim bodies are not
/// recovered. We chose that over "write failed but RAM hit" and over
/// fail-closing the whole instance on a transient durable-meta error.
/// [BytesResolver] write-through still sees the thrown [write] and
/// reports via diagnostics without failing a successful network resolve.
///
/// After [close], further operations throw [StateError].
///
/// Also implements [IBytesRichCache]: [readRich] returns the same hit or
/// miss as [read], and attaches [BytesRecord] timestamps plus
/// [HttpCacheMeta] when the index row has them.
final class IndexedBytesCache implements IBytesCache, IBytesRichCache {
  /// Wires [index] and [blobs] under [retention].
  ///
  /// [clock] is injectable for tests (defaults to UTC now).
  /// [reclaimOrphans] runs from [reclaimOrphans] and at the end of [prune]
  /// under the exclusive gate. Pass the platform blob store’s reclaim so
  /// wrappers never reclaim outside this domain.
  IndexedBytesCache({
    required IBytesIndex index,
    required IBytesBlobStore blobs,
    this.retention = BytesRetention.standard,
    DateTime Function()? clock,
    Future<void> Function(Set<String> indexedKeys)? reclaimOrphans,
  }) : _index = index,
       _blobs = blobs,
       _clock = clock ?? _defaultClock,
       _reclaimOrphans = reclaimOrphans;

  final IBytesIndex _index;
  final IBytesBlobStore _blobs;
  final Future<void> Function(Set<String> indexedKeys)? _reclaimOrphans;

  /// Eviction policy for this instance.
  final BytesRetention retention;
  final DateTime Function() _clock;

  final Map<BytesCacheKey, DateTime> _pendingAccess = {};

  /// Shared/exclusive gate. Language primitives only, no Mutex package.
  ///
  /// Writers serialize on [_exclusiveTail]. Readers briefly chain on that same
  /// tail to bump [_readerCount], then run concurrently without holding the
  /// tail for the read body, so a writer that arrives mid-read waits on
  /// [_readersIdle] instead of racing the count.
  Future<void> _exclusiveTail = Future.value();
  var _readerCount = 0;
  Completer<void>? _readersIdle;

  var _closed = false;

  /// Reads payload after TTL check. Soft-touches access time (see class docs).
  ///
  /// Concurrent with other pure reads. TTL expiry and index-without-blob
  /// cleanup upgrade to the exclusive mutate path.
  @override
  Future<Uint8List?> read(BytesCacheKey key) async => (await readRich(key))?.bytes;

  /// Same probe as [read], then retention timestamps and [HttpCacheMeta]
  /// from the index row when the hit succeeds.
  @override
  Future<BytesRichHit?> readRich(BytesCacheKey key) async {
    final probe = await _runShared(() async {
      _ensureOpen();
      final record = await _index.get(key);
      if (record == null) return const _ReadProbe.miss();

      final now = _clock();
      if (retention.limits.maxAge case final maxAge? when now.difference(record.writtenAt) > maxAge) {
        return const _ReadProbe.needsDelete();
      }

      final bytes = await _blobs.read(key, knownByteLength: record.byteLength);
      if (bytes == null) return const _ReadProbe.needsIndexDelete();
      // Legacy / corrupt empty rows still count toward capacity; scrub as miss.
      if (bytes.isEmpty) return const _ReadProbe.needsDelete();

      _pendingAccess[key] = now;
      return _ReadProbe.hit(
        bytes,
        writtenAt: record.writtenAt,
        accessedAt: now,
        httpCacheMeta: record.httpCacheMeta,
      );
    });

    return switch (probe) {
      _ReadProbeHit(
        :final bytes,
        :final writtenAt,
        :final accessedAt,
        :final httpCacheMeta,
      ) =>
        BytesRichHit(
          bytes: bytes,
          writtenAt: writtenAt,
          accessedAt: accessedAt,
          httpCacheMeta: httpCacheMeta,
        ),
      _ReadProbeMiss() => null,
      _ReadProbeNeedsDelete() => _runExclusive(() async {
        _ensureOpen();
        final preEpoch = await _captureIndexSnapshot();
        // Re-check under the exclusive gate: a write may have refreshed the
        // entry after the shared probe decided it was expired.
        final record = await _index.get(key);
        if (record == null) return null;
        final now = _clock();
        final expired = switch (retention.limits.maxAge) {
          final maxAge? => now.difference(record.writtenAt) > maxAge,
          null => false,
        };
        if (!expired) {
          return _finishSharedRichHit(key, now, preEpoch, record);
        }
        await _deleteBoth(key);
        await _commitOrRollback(preEpoch);
        return null;
      }),
      _ReadProbeNeedsIndexDelete() => _runExclusive(() async {
        _ensureOpen();
        final preEpoch = await _captureIndexSnapshot();
        // Re-check: a write may have restored the blob after the shared probe.
        final record = await _index.get(key);
        if (record == null) return null;
        final bytes = await _blobs.read(key, knownByteLength: record.byteLength);
        switch (bytes) {
          case final b? when b.isNotEmpty:
            final now = _clock();
            _pendingAccess[key] = now;
            return BytesRichHit(
              bytes: b,
              writtenAt: record.writtenAt,
              accessedAt: now,
              httpCacheMeta: record.httpCacheMeta,
            );
          case final b? when b.isEmpty:
            _pendingAccess.remove(key);
            await _deleteBoth(key);
            await _commitOrRollback(preEpoch);
            return null;
          case null:
            _pendingAccess.remove(key);
            await _index.delete(key);
            await _commitOrRollback(preEpoch);
            return null;
        }
      }),
    };
  }

  /// Blob hit after meta was already confirmed present and not expired.
  Future<BytesRichHit?> _finishSharedRichHit(
    BytesCacheKey key,
    DateTime now,
    Map<BytesCacheKey, BytesRecord> preEpoch,
    BytesRecord record,
  ) async {
    final bytes = await _blobs.read(key, knownByteLength: record.byteLength);
    if (bytes == null || bytes.isEmpty) {
      _pendingAccess.remove(key);
      await _deleteBoth(key);
      await _commitOrRollback(preEpoch);
      return null;
    }
    _pendingAccess[key] = now;
    return BytesRichHit(
      bytes: bytes,
      writtenAt: record.writtenAt,
      accessedAt: now,
      httpCacheMeta: record.httpCacheMeta,
    );
  }

  /// Writes payload and RAM meta, flushes soft access, trims, commits once.
  ///
  /// Empty [bytes] evict [key] instead of storing a zero-length row that would
  /// still occupy an entry slot under capacity retention.
  ///
  /// [httpCacheMeta] is written onto the index row. Null clears prior HTTP meta
  /// for [key] (bytes-only replace of a body that may have had validators).
  @override
  Future<void> write(
    BytesCacheKey key,
    Uint8List bytes, {
    HttpCacheMeta? httpCacheMeta,
  }) {
    if (bytes.isEmpty) {
      return evict(key);
    }
    return _runExclusive(() async {
      _ensureOpen();
      final preEpoch = await _captureIndexSnapshot();
      await _flushPendingAccess();
      final now = _clock();
      await _blobs.write(key, bytes);
      await _index.put(
        BytesRecord(
          key: key,
          writtenAt: now,
          accessedAt: now,
          byteLength: bytes.length,
          httpCacheMeta: httpCacheMeta,
        ),
      );
      await _trimCapacity();
      await _commitOrRollback(preEpoch);
    });
  }

  /// Removes index row, payload, and any pending access for [key].
  @override
  Future<void> evict(BytesCacheKey key) => _runExclusive(() async {
    _ensureOpen();
    final preEpoch = await _captureIndexSnapshot();
    _pendingAccess.remove(key);
    await _deleteBoth(key);
    await _commitOrRollback(preEpoch);
  });

  /// Flushes soft access, drops expired entries, capacity-trims, commits once,
  /// then reclaims orphan blobs under the same exclusive gate.
  @override
  Future<BytesPruneReport> prune() => _runExclusive(() async {
    _ensureOpen();
    final preEpoch = await _captureIndexSnapshot();
    await _flushPendingAccess();
    final evicted = <BytesCacheKey>[];
    var freed = 0;
    final now = _clock();

    if (retention.limits.maxAge case final maxAge?) {
      final expired = [
        for (final record in await _index.values())
          if (now.difference(record.writtenAt) > maxAge) record,
      ];
      for (final record in expired) {
        freed += record.byteLength;
        evicted.add(record.key);
        await _deleteBoth(record.key);
      }
    }

    freed += await _trimCapacity(evicted: evicted);
    await _commitOrRollback(preEpoch);
    await _reclaimOrphansUnlocked();
    return BytesPruneReport(evictedKeys: evicted, freedBytes: freed);
  });

  /// Drops blob keys absent from the index, under the exclusive mutate gate.
  ///
  /// No-op when no [reclaimOrphans] callback was supplied. Hosts / open paths
  /// call this after open; [prune] already reclaims at epoch end.
  Future<void> reclaimOrphans() => _runExclusive(() async {
    _ensureOpen();
    await _reclaimOrphansUnlocked();
  });

  /// Marks this instance closed and drops soft-access state.
  ///
  /// Idempotent. Waits for in-flight shared and exclusive work. Platform
  /// compositions may wrap this type for IO handles; this brain holds none.
  @override
  Future<void> close() => _runExclusive(() async {
    if (_closed) return;
    _closed = true;
    _pendingAccess.clear();
  });

  /// Registers as a reader on [_exclusiveTail], then runs [action] without
  /// holding the tail so other readers can overlap.
  Future<T> _runShared<T>(Future<T> Function() action) {
    final ready = Completer<void>();
    final previous = _exclusiveTail;
    _exclusiveTail = previous.catchError((Object _, StackTrace __) {}).then((_) {
      _readerCount++;
      ready.complete();
    });
    return ready.future.then((_) async {
      try {
        return await action();
      } finally {
        _readerCount--;
        if (_readerCount == 0) {
          _readersIdle?.complete();
          _readersIdle = null;
        }
      }
    });
  }

  /// Exclusive mutate: serialize writers, drain readers, then run.
  ///
  /// Ignores prior failures so one thrown op does not permanently stall the
  /// queue.
  Future<T> _runExclusive<T>(Future<T> Function() action) {
    final done = Completer<void>();
    final previous = _exclusiveTail;
    _exclusiveTail = done.future;
    return previous.catchError((Object _, StackTrace __) {}).then((_) async {
      while (_readerCount > 0) {
        final idle = Completer<void>();
        _readersIdle = idle;
        // Reader may have drained between the while check and assign.
        if (_readerCount == 0) {
          _readersIdle = null;
          break;
        }
        await idle.future;
      }
      try {
        return await action();
      } finally {
        if (!done.isCompleted) done.complete();
      }
    });
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('IndexedBytesCache is closed');
    }
  }

  /// Last-good RAM meta before this mutate epoch touches the mirror.
  ///
  /// [BytesRecord] is immutable, so holding the instances is a faithful
  /// snapshot of the pre-epoch map.
  Future<Map<BytesCacheKey, BytesRecord>> _captureIndexSnapshot() async => {
    for (final record in await _index.values()) record.key: record,
  };

  /// Persists once; on failure restores the RAM mirror to [preEpoch] and rethrows.
  ///
  /// Without rollback, a thrown commit would leave optimistic puts/deletes as
  /// in-process hits that no longer match durable storage ("write failed but
  /// hit"). Blob IO is not rolled back. A failed write may leave an orphan
  /// blob. A failed commit after trim, evict, or TTL may put index rows back
  /// whose payloads were already deleted; the next read heals those as
  /// index-without-blob, and those previously durable bodies stay gone. That
  /// cost beats fail-closing the whole instance on a transient meta error.
  Future<void> _commitOrRollback(Map<BytesCacheKey, BytesRecord> preEpoch) async {
    try {
      await _index.commit();
    } catch (error, stackTrace) {
      await _restoreIndexMirror(preEpoch);
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _restoreIndexMirror(Map<BytesCacheKey, BytesRecord> before) async {
    final current = (await _index.values()).toList();
    for (final record in current) {
      if (!before.containsKey(record.key)) {
        await _index.delete(record.key);
      }
    }
    for (final MapEntry(:key, :value) in before.entries) {
      final live = await _index.get(key);
      if (live == null ||
          live.writtenAt != value.writtenAt ||
          live.accessedAt != value.accessedAt ||
          live.byteLength != value.byteLength ||
          live.httpCacheMeta != value.httpCacheMeta) {
        await _index.put(value);
      }
    }
  }

  Future<void> _flushPendingAccess() async {
    if (_pendingAccess.isEmpty) return;
    final pending = Map<BytesCacheKey, DateTime>.of(_pendingAccess);
    _pendingAccess.clear();
    for (final MapEntry(:key, :value) in pending.entries) {
      final record = await _index.get(key);
      if (record == null) continue;
      await _index.put(record.copyWith(accessedAt: value));
    }
  }

  Future<void> _deleteBoth(BytesCacheKey key) async {
    _pendingAccess.remove(key);
    await _index.delete(key);
    await _blobs.delete(key);
  }

  Future<void> _reclaimOrphansUnlocked() async {
    final reclaim = _reclaimOrphans;
    if (reclaim == null) return;
    final keys = {for (final record in await _index.values()) record.key.value};
    await reclaim(keys);
  }

  Future<int> _trimCapacity({List<BytesCacheKey>? evicted}) async {
    final limits = retention.limits;
    var freed = 0;

    while (true) {
      final records = (await _index.values()).toList();
      final totalBytes = records.fold<int>(0, (s, e) => s + e.byteLength);
      final overEntries = switch (limits.maxEntries) {
        final max? => records.length > max,
        null => false,
      };
      final overBytes = switch (limits.maxBytes) {
        final max? => totalBytes > max,
        null => false,
      };
      if (!overEntries && !overBytes) break;
      if (records.isEmpty) break;

      records.sort((a, b) => a.accessedAt.compareTo(b.accessedAt));
      final victim = records.first;
      freed += victim.byteLength;
      evicted?.add(victim.key);
      await _deleteBoth(victim.key);
    }
    return freed;
  }
}

/// Outcome of a shared [IndexedBytesCache.readRich] probe before optional mutate.
@immutable
sealed class _ReadProbe {
  const _ReadProbe();

  const factory _ReadProbe.hit(
    Uint8List bytes, {
    required DateTime writtenAt,
    required DateTime accessedAt,
    HttpCacheMeta? httpCacheMeta,
  }) = _ReadProbeHit;
  const factory _ReadProbe.miss() = _ReadProbeMiss;
  const factory _ReadProbe.needsDelete() = _ReadProbeNeedsDelete;
  const factory _ReadProbe.needsIndexDelete() = _ReadProbeNeedsIndexDelete;
}

@immutable
final class _ReadProbeHit extends _ReadProbe {
  const _ReadProbeHit(
    this.bytes, {
    required this.writtenAt,
    required this.accessedAt,
    this.httpCacheMeta,
  });

  final Uint8List bytes;
  final DateTime writtenAt;
  final DateTime accessedAt;
  final HttpCacheMeta? httpCacheMeta;
}

@immutable
final class _ReadProbeMiss extends _ReadProbe {
  const _ReadProbeMiss();
}

@immutable
final class _ReadProbeNeedsDelete extends _ReadProbe {
  const _ReadProbeNeedsDelete();
}

@immutable
final class _ReadProbeNeedsIndexDelete extends _ReadProbe {
  const _ReadProbeNeedsIndexDelete();
}

DateTime _defaultClock() => DateTime.now().toUtc();

/// In-memory [IBytesCache] for tests (and rare L1 use).
///
/// Access times update on every [read] (cheap in memory). Prefer
/// [IndexedBytesCache] for the process store.
///
/// Keeps optional [HttpCacheMeta] in the same map entry as the bytes.
/// [readRich] and a middleware `execute` read can return it without a durable
/// index.
final class MemoryBytesCache implements IBytesCache, IBytesRichCache {
  /// Creates an empty in-memory store.
  ///
  /// [clock] is injectable for tests (defaults to UTC now).
  MemoryBytesCache({
    this.retention = const BytesRetention.unlimited(),
    DateTime Function()? clock,
  }) : _clock = clock ?? _defaultClock;

  /// Eviction policy for this instance.
  final BytesRetention retention;
  final DateTime Function() _clock;

  final Map<BytesCacheKey, _MemoryEntry> _entries = {};

  /// Returns bytes or `null` if missing / past TTL / empty sticky payload.
  @override
  Future<Uint8List?> read(BytesCacheKey key) async => (await readRich(key))?.bytes;

  /// Same miss rules as [read], plus timestamps and [HttpCacheMeta].
  @override
  Future<BytesRichHit?> readRich(BytesCacheKey key) async {
    if (_entries[key] case final entry?) {
      final now = _clock();
      if (retention.limits.maxAge case final maxAge? when now.difference(entry.writtenAt) > maxAge) {
        _entries.remove(key);
        return null;
      }
      if (entry.bytes.isEmpty) {
        _entries.remove(key);
        return null;
      }

      entry.accessedAt = now;
      return BytesRichHit(
        bytes: entry.bytes,
        writtenAt: entry.writtenAt,
        accessedAt: entry.accessedAt,
        httpCacheMeta: entry.httpCacheMeta,
      );
    }
    return null;
  }

  /// Stores [bytes] and trims capacity if needed.
  ///
  /// Empty [bytes] evict [key] instead of retaining a zero-length entry that
  /// still consumes [BytesRetention.maxEntries] capacity.
  ///
  /// [httpCacheMeta] lives in the entry for [readRich]. Null clears prior meta.
  @override
  Future<void> write(
    BytesCacheKey key,
    Uint8List bytes, {
    HttpCacheMeta? httpCacheMeta,
  }) async {
    if (bytes.isEmpty) {
      _entries.remove(key);
      return;
    }
    final now = _clock();
    _entries[key] = _MemoryEntry(
      bytes: bytes,
      writtenAt: now,
      accessedAt: now,
      httpCacheMeta: httpCacheMeta,
    );
    _trimCapacity();
  }

  /// Removes [key] if present.
  @override
  Future<void> evict(BytesCacheKey key) async {
    _entries.remove(key);
  }

  /// Drops expired entries then capacity-trims.
  @override
  Future<BytesPruneReport> prune() async {
    final evicted = <BytesCacheKey>[];
    var freed = 0;
    final now = _clock();

    if (retention.limits.maxAge case final maxAge?) {
      final expired = _entries.entries
          .where((e) => now.difference(e.value.writtenAt) > maxAge)
          .map((e) => e.key)
          .toList();
      for (final key in expired) {
        if (_entries.remove(key) case final entry?) {
          freed += entry.bytes.length;
          evicted.add(key);
        }
      }
    }

    freed += _trimCapacity(evicted: evicted);
    return BytesPruneReport(evictedKeys: evicted, freedBytes: freed);
  }

  /// No resources to release. Idempotent so tearDown can call [close] uniformly.
  @override
  Future<void> close() async {}

  int _trimCapacity({List<BytesCacheKey>? evicted}) {
    final limits = retention.limits;
    var freed = 0;

    bool overCapacity() {
      if (limits.maxEntries case final maxEntries? when _entries.length > maxEntries) {
        return true;
      }
      if (limits.maxBytes case final maxBytes?) {
        final total = _entries.values.fold<int>(0, (s, e) => s + e.bytes.length);
        if (total > maxBytes) return true;
      }
      return false;
    }

    while (overCapacity() && _entries.isNotEmpty) {
      final oldest = _entries.entries.reduce(
        (a, b) => a.value.accessedAt.isBefore(b.value.accessedAt) ? a : b,
      );
      freed += oldest.value.bytes.length;
      _entries.remove(oldest.key);
      evicted?.add(oldest.key);
    }
    return freed;
  }
}

final class _MemoryEntry {
  _MemoryEntry({
    required this.bytes,
    required this.writtenAt,
    required this.accessedAt,
    this.httpCacheMeta,
  });

  final Uint8List bytes;
  final DateTime writtenAt;
  DateTime accessedAt;
  final HttpCacheMeta? httpCacheMeta;
}

/// Always misses. Used until bootstrap calls [BytesCache.configure].
final class NoOpBytesCache implements IBytesCache {
  /// Shared no-op instance is fine; this type holds no state.
  const NoOpBytesCache();

  /// Always `null`.
  @override
  Future<Uint8List?> read(BytesCacheKey key) async => null;

  /// Discards [bytes] and [httpCacheMeta]. Nothing is stored.
  @override
  Future<void> write(
    BytesCacheKey key,
    Uint8List bytes, {
    HttpCacheMeta? httpCacheMeta,
  }) async {}

  /// Nothing to remove.
  @override
  Future<void> evict(BytesCacheKey key) async {}

  /// Returns an empty [BytesPruneReport].
  @override
  Future<BytesPruneReport> prune() async => const BytesPruneReport(evictedKeys: [], freedBytes: 0);

  /// No resources to release. Idempotent so tearDown can call [close] uniformly.
  @override
  Future<void> close() async {}
}

/// Process-wide [IBytesCache] and the way to open the durable store.
abstract final class BytesCache {
  /// Shared instance. [NoOpBytesCache] until [configure] or [debugShared].
  static IBytesCache shared() => debugShared ?? _shared ?? const NoOpBytesCache();

  static IBytesCache? _shared;

  /// Opens the environment-specific durable store.
  ///
  /// On VM, [directory] is required (hosts should pass a path under the app
  /// cache root, not documents) and the store is a file index plus
  /// one-file-per-key blobs on a long-lived isolate worker.
  ///
  /// On web, [directory] is ignored; a Cache API index document plus Cache API
  /// blobs for small bodies and OPFS files for large ones back the same
  /// [IBytesCache] contract.
  ///
  /// [diagnostics] is installed on [BytesDiagnostics.current] before the
  /// store opens so index wipe recovery can report under the same policy as
  /// later resolve write-through.
  ///
  /// Hard open failures (quota, private mode, filesystem / Cache / OPFS errors)
  /// degrade to [MemoryBytesCache] with a warning unless
  /// [throwOnOpenFailure] is true. Platform open hooks close any partially
  /// opened VM worker or web handles before the failure surfaces here, so
  /// neither degrade nor strict rethrow leaks isolates or Cache/OPFS quota.
  /// [ArgumentError] from a missing VM [directory] still throws: that is a
  /// host wiring bug, not storage unavailability.
  static Future<IBytesCache> open({
    String? directory,
    BytesRetention retention = BytesRetention.standard,
    DateTime Function()? clock,
    BytesDiagnostics diagnostics = const BytesDiagnostics.silent(),
    bool throwOnOpenFailure = false,
  }) async {
    BytesDiagnostics.current = diagnostics;
    try {
      return await environment_specific.$openBytesCache(
        directory: directory,
        retention: retention,
        clock: clock,
      );
    } on Object catch (error, stackTrace) {
      // Missing VM directory is ArgumentError (host wiring), not storage failure.
      if (error case ArgumentError()) rethrow;
      if (throwOnOpenFailure) rethrow;
      diagnostics.report(
        BytesLogEvent(
          level: BytesLogLevel.warning,
          message: 'image bytes cache: open failed, using in-memory store: $error',
          op: BytesLogOp.openDegraded,
          stackTrace: stackTrace,
        ),
      );
      return MemoryBytesCache(retention: retention, clock: clock);
    }
  }

  /// Sets the process-wide store (bootstrap).
  ///
  /// Closes any previous non-identical [_shared] instance **before** assign so
  /// workers and Cache handles do not leak across reconfigure, and two durable
  /// stores never share the same process slot at once.
  ///
  /// Pass [diagnostics] when the store was opened without one, or to replace
  /// the policy after open. Omit to keep the policy [open] already installed.
  static Future<void> configure(
    IBytesCache cache, {
    BytesDiagnostics? diagnostics,
  }) async {
    if (diagnostics != null) {
      BytesDiagnostics.current = diagnostics;
    }
    final previous = _shared;
    if (previous != null && !identical(previous, cache)) {
      await previous.close();
    }
    _shared = cache;
  }

  /// Test override. Set to `null` to clear.
  @visibleForTesting
  static IBytesCache? debugShared;

  /// Closes the previous shared instance, then clears [configure] and
  /// [debugShared], and resets diagnostics to silent.
  ///
  /// Also invokes registered ladder cleanup hooks (see
  /// [addAfterResetShared]) so resolver / client shared wiring can clear
  /// without this facade importing those libraries.
  @visibleForTesting
  static Future<void> resetShared() async {
    final previous = _shared;
    debugShared = null;
    BytesDiagnostics.current = const BytesDiagnostics.silent();
    await previous?.close();
    _shared = null;
    for (final hook in List<FutureOr<void> Function()>.of(_afterResetSharedHooks)) {
      await hook();
    }
  }

  static final List<FutureOr<void> Function()> _afterResetSharedHooks = [];

  /// Registers cleanup after [resetShared] (resolver memo, client shared, …).
  ///
  /// Hooks are package-internal so the store facade does not import the ladder
  /// above it. Idempotent registration is the caller's responsibility.
  @internal
  static void addAfterResetShared(FutureOr<void> Function() hook) {
    _afterResetSharedHooks.add(hook);
  }
}
