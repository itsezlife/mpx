// ignore_for_file: one_member_abstracts

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http_bytes_cache/src/bytes_diagnostics.dart';
import 'package:http_bytes_cache/src/environment_specific/cache_open.dart'
    as environment_specific;
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
    var safeName = pathSeg
        .replaceAll(RegExp('[^a-zA-Z0-9._-]'), '_')
        .replaceAll('..', '_');
    final fingerprint = sha1
        .convert(_fingerprintMaterial(canonicalUrl, headers))
        .toString()
        .substring(0, 12);
    // Reserve room for host + '_' + '_' + 12-char fingerprint.
    final maxNameLen = (_maxValueLength - host.length - fingerprint.length - 2)
        .clamp(8, _maxBasenameLength);
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
        if (!_conditionalRequestHeaders.contains(key.toLowerCase()))
          key.toLowerCase(): value,
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
  static List<int> _fingerprintMaterial(
    String canonicalUrl,
    Map<String, String>? headers,
  ) {
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
  bool operator ==(Object other) =>
      identical(this, other) || other is BytesCacheKey && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'BytesCacheKey($value)';
}

/// How long / how much an [IBytesCache] keeps entries, across all quotas.
///
/// Age counts from last use ([BytesRecord.accessedAt]), not from the write: a
/// body used daily never expires. Age is checked on [IBytesCache.read].
/// Capacity is trimmed on [IBytesCache.write] and [IBytesCache.prune]; it is
/// the store's total budget, shared by its [BytesQuota]s. There is no
/// background timer: without those calls, entries stay until the host deletes
/// them.
@immutable
sealed class BytesRetention {
  const BytesRetention();

  /// No automatic eviction (still removable via [IBytesCache.evict]).
  const factory BytesRetention.unlimited() = BytesRetentionUnlimited;

  /// Drop a row not used for longer than [maxAge].
  const factory BytesRetention.maxAge(Duration maxAge) = BytesRetentionMaxAge;

  /// Keep at most [maxEntries] (LRU by last access).
  ///
  /// [maxEntries] must be positive — a zero or negative cap is nonsense
  /// retention that would either retain nothing useful or never trim.
  const factory BytesRetention.maxEntries(int maxEntries) =
      BytesRetentionMaxEntries;

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
  /// Drops what was not used for a month, and caps the whole store at
  /// 10 000 entries and 1 GiB, which the [BytesQuota.standard] quotas share.
  /// The entry cap bounds the index document every commit rewrites; the byte
  /// budget bounds the disk without a background eviction timer.
  static const BytesRetention standard = BytesRetentionCompound(
    maxAge: Duration(days: 30),
    maxEntries: 10000,
    maxBytes: 1024 * 1024 * 1024,
  );

  /// Whether a row anchored at [anchor] is past [limits]' `maxAge` at [now].
  ///
  /// False when the policy sets no age.
  bool isExpired(DateTime anchor, {required DateTime now}) =>
      switch (limits.maxAge) {
        final maxAge? => now.difference(anchor) > maxAge,
        null => false,
      };

  /// Flattened view of this policy for implementers.
  ({Duration? maxAge, int? maxEntries, int? maxBytes}) get limits =>
      switch (this) {
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

  /// Maximum time since last use.
  final Duration maxAge;
}

/// Variant of [BytesRetention.maxEntries].
@immutable
final class BytesRetentionMaxEntries extends BytesRetention {
  /// See [BytesRetention.maxEntries].
  const BytesRetentionMaxEntries(this.maxEntries)
    : assert(maxEntries > 0, 'maxEntries must be > 0');

  /// Maximum number of keys retained.
  final int maxEntries;
}

/// Variant of [BytesRetention.maxBytes].
@immutable
final class BytesRetentionMaxBytes extends BytesRetention {
  /// See [BytesRetention.maxBytes].
  const BytesRetentionMaxBytes(this.maxBytes)
    : assert(maxBytes > 0, 'maxBytes must be > 0');

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
  }) : assert(
         maxEntries == null || maxEntries > 0,
         'maxEntries must be > 0 when set',
       ),
       assert(
         maxBytes == null || maxBytes > 0,
         'maxBytes must be > 0 when set',
       );

  /// Optional maximum time since last use.
  final Duration? maxAge;

  /// Optional max key count.
  final int? maxEntries;

  /// Optional max total payload bytes.
  final int? maxBytes;
}

/// A named share of the store's budget, so one kind of media cannot evict
/// every other.
///
/// Every row belongs to one quota ([BytesRecord.quota]). A quota over its own
/// [maxBytes] / [maxEntries] gives back space from its own least recently used
/// rows only. When the store as a whole is over its [BytesRetention] budget,
/// the quota furthest over its share (bytes used / [maxBytes]) gives back
/// first, so a long video cannot evict every avatar.
///
/// Identity is [name]. A store takes the limits of the quota it was configured
/// with; a write naming a quota the store was not configured with brings its
/// own limits.
@immutable
final class BytesQuota {
  /// A quota named [name]; null limits mean only the store budget applies.
  const BytesQuota(this.name, {this.maxBytes, this.maxEntries})
    : assert(maxBytes == null || maxBytes > 0, 'maxBytes must be > 0'),
      assert(maxEntries == null || maxEntries > 0, 'maxEntries must be > 0');

  /// Identity of the quota; persisted on every row.
  final String name;

  /// Bytes this quota may hold before it evicts within itself.
  final int? maxBytes;

  /// Rows this quota may hold before it evicts within itself.
  final int? maxEntries;

  /// Still images, stickers, avatars: 256 MiB. Rows written without a quota,
  /// and rows stored before quotas existed, belong here.
  static const BytesQuota images = BytesQuota(
    _defaultQuotaName,
    maxBytes: 256 * 1024 * 1024,
  );

  /// Byte ranges of streamed video: 768 MiB.
  static const BytesQuota videoRanges = BytesQuota(
    'video_ranges',
    maxBytes: 768 * 1024 * 1024,
  );

  /// Rendered Lottie frame caches: 256 MiB.
  static const BytesQuota lottieFrames = BytesQuota(
    'lottie_frames',
    maxBytes: 256 * 1024 * 1024,
  );

  /// Glyph atlas pages: 32 MiB.
  static const BytesQuota glyphs = BytesQuota(
    'glyphs',
    maxBytes: 32 * 1024 * 1024,
  );

  /// The four quotas [BytesCache.open] configures by default.
  static const List<BytesQuota> standard = [
    images,
    videoRanges,
    lottieFrames,
    glyphs,
  ];

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is BytesQuota && other.name == name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => 'BytesQuota($name)';
}

const String _defaultQuotaName = 'images';

/// Frees up to `bytes` from a registered quota's files and returns how many
/// bytes it freed (0 when it could free nothing).
typedef QuotaEvictor = Future<int> Function(int bytes);

/// A [BytesQuota] over files another owner keeps (a frame cache, glyph
/// pages), counted against the store's one budget.
///
/// The store never reads, lists or deletes those files. The owner reports how
/// many bytes it holds with [reportUsage]; when the store decides this quota
/// must give back space it calls the owner's [QuotaEvictor] with the bytes it
/// needs, and takes the returned count off [usedBytes]. A report that pushes
/// the quota or the store over budget makes the store run an eviction pass on
/// its own, without waiting for its next write.
///
/// The evictor runs inside the store's exclusive mutate domain: it must not
/// await operations on the same store.
final class RegisteredQuota {
  /// Registration of [quota] for an owner whose files [onEvict] frees.
  ///
  /// Stores build these from [IBytesStore.registerQuota]; [onUsage] and
  /// [onUnregister] are the store's hooks.
  RegisteredQuota({
    required this.quota,
    required QuotaEvictor onEvict,
    void Function()? onUsage,
    void Function()? onUnregister,
  }) : _onEvict = onEvict,
       _onUsage = onUsage,
       _onUnregister = onUnregister;

  /// The quota whose budget the owner's files count against.
  final BytesQuota quota;

  final QuotaEvictor _onEvict;
  final void Function()? _onUsage;
  final void Function()? _onUnregister;
  var _usedBytes = 0;
  var _registered = true;

  /// Bytes the owner last reported, less what it freed since.
  int get usedBytes => _usedBytes;

  /// Whether the store still counts this quota.
  bool get isRegistered => _registered;

  /// Sets the bytes the owner's files take now. Ignored after [unregister].
  void reportUsage(int bytes) {
    if (!_registered) return;
    _usedBytes = bytes < 0 ? 0 : bytes;
    _onUsage?.call();
  }

  /// Stops counting this quota; the store never asks it again. Idempotent.
  void unregister() {
    if (!_registered) return;
    _registered = false;
    _onUnregister?.call();
  }

  /// Asks the owner to free [bytes]; returns what it freed. Store side.
  @internal
  Future<int> evict(int bytes) async {
    final freed = await _onEvict(bytes);
    final taken = freed.clamp(0, _usedBytes);
    _usedBytes -= taken;
    return taken;
  }
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
    this.quota = _defaultQuotaName,
    this.payloadKey,
  });

  /// Entry identity.
  final BytesCacheKey key;

  /// Key the payload is stored under when it is not [key]: an alias row
  /// ([IBytesStore.alias]) reads another row's payload. Null for a row that
  /// owns its payload.
  final BytesCacheKey? payloadKey;

  /// Key of the payload this row reads.
  BytesCacheKey get payload => payloadKey ?? key;

  /// [BytesQuota.name] of the quota this row counts against.
  final String quota;

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
    String? quota,
    BytesCacheKey? payloadKey,
  }) => BytesRecord(
    key: key,
    writtenAt: writtenAt ?? this.writtenAt,
    accessedAt: accessedAt ?? this.accessedAt,
    byteLength: byteLength ?? this.byteLength,
    httpCacheMeta: httpCacheMeta ?? this.httpCacheMeta,
    quota: quota ?? this.quota,
    payloadKey: payloadKey ?? this.payloadKey,
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

  /// Same as [get], answered synchronously from the RAM mirror.
  ///
  /// Backs [IBytesStore.contains], which must answer without awaiting.
  BytesRecord? peek(BytesCacheKey key);

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

/// Payload port that keeps each payload in a file it can name.
///
/// [IndexedBytesCache] hands out [FileLease]s only over a blob store of this
/// kind; stores without files (memory, browser storage) hand out none.
abstract interface class IBytesFileBlobStore implements IBytesBlobStore {
  /// Absolute path of the payload file for [key], whether or not it exists.
  String pathOf(BytesCacheKey key);
}

/// A held path to a stored payload file.
///
/// While a lease is held, eviction, expiry and orphan reclaim leave the file in
/// place, so a decoder or a native player can open the path at any time. An
/// explicit [IBytesCache.evict] of a leased key drops the key at once and
/// deletes the file when the last lease on it is released. Rewriting a leased
/// key replaces the file atomically: a reader that already opened it keeps the
/// old bytes, a later open sees the new ones.
///
/// [release] when done; it is idempotent. A lease outliving its store's close
/// releases as a no-op.
final class FileLease {
  /// Leases [path] for [key]; [onRelease] runs once, on the first [release].
  FileLease({
    required this.key,
    required this.path,
    required Future<void> Function() onRelease,
  }) : _onRelease = onRelease;

  /// The key the lease was taken for.
  final BytesCacheKey key;

  /// Absolute path of the payload file.
  final String path;

  final Future<void> Function() _onRelease;
  var _released = false;

  /// Whether [release] already ran.
  bool get isReleased => _released;

  /// Gives the file back to eviction. Idempotent.
  Future<void> release() {
    if (_released) return Future<void>.value();
    _released = true;
    return _onRelease();
  }
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
  ///
  /// [quota] is the [BytesQuota] the row counts against. Null keeps the quota
  /// of the row [key] already has, else [BytesQuota.images]. Stores without
  /// quotas ignore it.
  Future<void> write(
    BytesCacheKey key,
    Uint8List bytes, {
    HttpCacheMeta? httpCacheMeta,
    BytesQuota? quota,
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

/// The one store behind the resolve ladder: an [IBytesCache] with the
/// queries and handles that need its index.
///
/// [IndexedBytesCache] (and the platform stores [BytesCache.open] returns)
/// and [MemoryBytesCache] implement it; a [MiddlewareBytesCache] does when its
/// inner store does.
abstract interface class IBytesStore implements IBytesCache, IBytesRichCache {
  /// Whether [key] holds bytes now, answered from RAM without any IO.
  ///
  /// A row past its retention age answers false. Optimistic about payloads:
  /// a row whose payload went missing answers true until a read heals it.
  bool contains(BytesCacheKey key);

  /// Leases the payload file of [key], or null when [key] holds nothing or the
  /// store keeps no files. Taking a lease counts as a use of [key].
  Future<FileLease?> leaseFile(BytesCacheKey key);

  /// Counts files another owner keeps against [quota] (see
  /// [RegisteredQuota]); [onEvict] frees them when the store asks.
  ///
  /// Throws [StateError] when a quota of that name is already registered.
  RegisteredQuota registerQuota(
    BytesQuota quota, {
    required QuotaEvictor onEvict,
  });

  /// Makes [server] resolve to the bytes [local] holds, with no copy or move.
  ///
  /// The two keys share one payload from then on: each keeps its own last use
  /// and expires on its own, and the payload goes when no key reads it. When
  /// [server] already held bytes, the alias replaces them. Aliasing a key that
  /// is itself an alias points at the same payload, so chains stay flat.
  /// Returns false, changing nothing, when [local] holds nothing.
  Future<bool> alias(BytesCacheKey local, BytesCacheKey server);

  /// Drops [local] once its bytes answer for a server key (or are no longer
  /// wanted); retention drops it otherwise. Keys aliased to it keep the
  /// bytes. Same as [evict], named for the producer's side of [alias].
  Future<void> release(BytesCacheKey local);
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
final class IndexedBytesCache implements IBytesStore {
  /// Wires [index] and [blobs] under [retention], shared by [quotas].
  ///
  /// [clock] is injectable for tests (defaults to UTC now).
  /// [reclaimOrphans] runs from [reclaimOrphans] and at the end of [prune]
  /// under the exclusive gate. Pass the platform blob store’s reclaim so
  /// wrappers never reclaim outside this domain.
  IndexedBytesCache({
    required IBytesIndex index,
    required IBytesBlobStore blobs,
    this.retention = BytesRetention.standard,
    Iterable<BytesQuota> quotas = BytesQuota.standard,
    DateTime Function()? clock,
    Future<void> Function(Set<String> indexedKeys)? reclaimOrphans,
  }) : _quotas = {for (final quota in quotas) quota.name: quota},
       _index = index,
       _blobs = blobs,
       _clock = clock ?? _defaultClock,
       _reclaimOrphans = reclaimOrphans;

  final IBytesIndex _index;
  final IBytesBlobStore _blobs;
  final Future<void> Function(Set<String> indexedKeys)? _reclaimOrphans;

  /// Eviction policy for this instance.
  final BytesRetention retention;
  final DateTime Function() _clock;

  /// Quotas by name: the configured ones, plus any a write brought along.
  final Map<String, BytesQuota> _quotas;

  final Map<BytesCacheKey, DateTime> _pendingAccess = {};

  /// Held [FileLease]s per payload key. Eviction, expiry and reclaim skip
  /// these payloads and the rows that read them.
  final Map<BytesCacheKey, int> _leases = {};

  /// Leased payloads no row reads any more; they go with the last lease.
  final Set<BytesCacheKey> _orphanedLeases = {};

  /// Quotas over files other owners keep, by quota name.
  final Map<String, RegisteredQuota> _registered = {};
  var _trimScheduled = false;

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

  @override
  bool contains(BytesCacheKey key) {
    _ensureOpen();
    final record = _index.peek(key);
    return record != null && _isLive(record, _clock());
  }

  @override
  Future<FileLease?> leaseFile(BytesCacheKey key) async {
    if (_blobs case final IBytesFileBlobStore files) {
      return _runShared(() async {
        _ensureOpen();
        final record = await _index.get(key);
        if (record == null) return null;
        final now = _clock();
        if (!_isLive(record, now)) return null;
        _pendingAccess[key] = now;
        final payload = record.payload;
        _leases.update(payload, (n) => n + 1, ifAbsent: () => 1);
        return FileLease(
          key: key,
          path: files.pathOf(payload),
          onRelease: () => _releaseLease(payload),
        );
      });
    }
    return null;
  }

  @override
  RegisteredQuota registerQuota(
    BytesQuota quota, {
    required QuotaEvictor onEvict,
  }) {
    _ensureOpen();
    if (_registered.containsKey(quota.name)) {
      throw StateError('Quota ${quota.name} is already registered');
    }
    _quotas.putIfAbsent(quota.name, () => quota);
    late final RegisteredQuota registered;
    registered = RegisteredQuota(
      quota: quota,
      onEvict: onEvict,
      onUsage: _scheduleTrim,
      onUnregister: () {
        if (identical(_registered[quota.name], registered)) {
          _registered.remove(quota.name);
        }
      },
    );
    return _registered[quota.name] = registered;
  }

  /// One eviction pass on the store's own initiative, after a registered
  /// quota reports usage. Coalesced: reports in a burst share one pass.
  void _scheduleTrim() {
    if (_trimScheduled || _closed) return;
    _trimScheduled = true;
    _runExclusive(() async {
      _trimScheduled = false;
      if (_closed) return;
      final preEpoch = await _captureIndexSnapshot();
      final evicted = <BytesCacheKey>[];
      await _trimCapacity(evicted: evicted);
      if (evicted.isNotEmpty) await _commitOrRollback(preEpoch);
    }).catchError((Object error, StackTrace stackTrace) {
      BytesDiagnostics.current.report(
        BytesLogEvent(
          level: BytesLogLevel.error,
          message: 'bytes store: eviction pass after a usage report: $error',
          op: BytesLogOp.quotaTrim,
          stackTrace: stackTrace,
        ),
      );
    });
  }

  Future<void> _releaseLease(BytesCacheKey payload) async {
    if (_closed) return;
    final left = _leases.update(payload, (n) => n - 1);
    if (left > 0) return;
    _leases.remove(payload);
    if (!_orphanedLeases.remove(payload)) return;
    await _runExclusive(() async {
      if (_closed || _leases.containsKey(payload)) return;
      // A write after the evict may have given the payload a reader again.
      if (!await _isReferenced(payload)) await _blobs.delete(payload);
    });
  }

  @override
  Future<bool> alias(BytesCacheKey local, BytesCacheKey server) =>
      _runExclusive(() async {
        _ensureOpen();
        final source = await _index.get(local);
        final now = _clock();
        if (source == null || !_isLive(source, now)) return false;
        final previous = await _index.get(server);
        if (previous?.payload == source.payload) return true;

        final preEpoch = await _captureIndexSnapshot();
        await _flushPendingAccess();
        await _index.put(
          BytesRecord(
            key: server,
            writtenAt: now,
            accessedAt: now,
            byteLength: source.byteLength,
            quota: source.quota,
            payloadKey: source.payload == server ? null : source.payload,
          ),
        );
        if (previous != null) await _dropPayloadIfUnread(previous.payload);
        await _commitOrRollback(preEpoch);
        return true;
      });

  @override
  Future<void> release(BytesCacheKey local) => evict(local);

  /// Leased rows stay live past their age: someone holds their file. Age
  /// counts from the last use, including one still soft in [_pendingAccess].
  bool _isLive(BytesRecord record, DateTime now) =>
      _leases.containsKey(record.payload) ||
      !retention.isExpired(_lastUse(record), now: now);

  DateTime _lastUse(BytesRecord record) =>
      _pendingAccess[record.key] ?? record.accessedAt;

  /// Reads payload after TTL check. Soft-touches access time (see class docs).
  ///
  /// Concurrent with other pure reads. TTL expiry and index-without-blob
  /// cleanup upgrade to the exclusive mutate path.
  @override
  Future<Uint8List?> read(BytesCacheKey key) async =>
      (await readRich(key))?.bytes;

  /// Same probe as [read], then retention timestamps and [HttpCacheMeta]
  /// from the index row when the hit succeeds.
  @override
  Future<BytesRichHit?> readRich(BytesCacheKey key) async {
    final probe = await _runShared(() async {
      _ensureOpen();
      final record = await _index.get(key);
      if (record == null) return const _ReadProbe.miss();

      final now = _clock();
      if (!_isLive(record, now)) {
        return const _ReadProbe.needsDelete();
      }

      final bytes = await _blobs.read(
        record.payload,
        knownByteLength: record.byteLength,
      );
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
        if (_isLive(record, now)) {
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
        final bytes = await _blobs.read(
          record.payload,
          knownByteLength: record.byteLength,
        );
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
    final bytes = await _blobs.read(
      record.payload,
      knownByteLength: record.byteLength,
    );
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
    BytesQuota? quota,
  }) {
    if (bytes.isEmpty) {
      return evict(key);
    }
    return _runExclusive(() async {
      _ensureOpen();
      final preEpoch = await _captureIndexSnapshot();
      await _flushPendingAccess();
      final now = _clock();
      if (quota != null) _quotas.putIfAbsent(quota.name, () => quota);
      final previous = await _index.get(key);
      final quotaName = quota?.name ?? previous?.quota ?? _defaultQuotaName;
      // The key gets its own payload: an alias row stops reading the shared
      // one, which stays for the keys still reading it.
      await _blobs.write(key, bytes);
      _orphanedLeases.remove(key);
      await _index.put(
        BytesRecord(
          key: key,
          writtenAt: now,
          accessedAt: now,
          byteLength: bytes.length,
          httpCacheMeta: httpCacheMeta,
          quota: quotaName,
        ),
      );
      if (previous case final row? when row.payload != key) {
        await _dropPayloadIfUnread(row.payload);
      }
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

    if (retention.limits.maxAge != null) {
      final expired = [
        for (final record in await _index.values())
          if (!_isLive(record, now)) record,
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
    _leases.clear();
    _orphanedLeases.clear();
    _registered.clear();
  });

  /// Registers as a reader on [_exclusiveTail], then runs [action] without
  /// holding the tail so other readers can overlap.
  Future<T> _runShared<T>(Future<T> Function() action) {
    final ready = Completer<void>();
    final previous = _exclusiveTail;
    _exclusiveTail = previous.catchError((Object _, StackTrace __) {}).then((
      _,
    ) {
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
  Future<void> _commitOrRollback(
    Map<BytesCacheKey, BytesRecord> preEpoch,
  ) async {
    try {
      await _index.commit();
    } catch (error, stackTrace) {
      await _restoreIndexMirror(preEpoch);
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _restoreIndexMirror(
    Map<BytesCacheKey, BytesRecord> before,
  ) async {
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
          live.httpCacheMeta != value.httpCacheMeta ||
          live.quota != value.quota ||
          live.payloadKey != value.payloadKey) {
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

  /// Drops [key]'s row, and its payload when no other row reads it.
  ///
  /// Pass [payloadStillRead] when the caller already knows (a trim pass
  /// counts references once), to skip the index scan.
  Future<void> _deleteBoth(BytesCacheKey key, {bool? payloadStillRead}) async {
    _pendingAccess.remove(key);
    final record = await _index.get(key);
    await _index.delete(key);
    final payload = record?.payload ?? key;
    if (payloadStillRead ?? await _isReferenced(payload)) return;
    await _dropUnreadPayload(payload);
  }

  Future<void> _dropPayloadIfUnread(BytesCacheKey payload) async {
    if (!await _isReferenced(payload)) await _dropUnreadPayload(payload);
  }

  /// Deletes a payload no row reads; a leased one waits for its release.
  Future<void> _dropUnreadPayload(BytesCacheKey payload) async {
    if (_leases.containsKey(payload)) {
      _orphanedLeases.add(payload);
    } else {
      await _blobs.delete(payload);
    }
  }

  Future<bool> _isReferenced(BytesCacheKey payload) async =>
      (await _index.values()).any((record) => record.payload == payload);

  Future<void> _reclaimOrphansUnlocked() async {
    final reclaim = _reclaimOrphans;
    if (reclaim == null) return;
    final keys = {
      for (final record in await _index.values()) record.payload.value,
      for (final key in _leases.keys) key.value,
    };
    await reclaim(keys);
  }

  /// One eviction pass over every quota; returns the bytes it freed.
  ///
  /// First each quota over its own limits gives back its least recently used
  /// rows. Then, while the store is over its [retention] budget, the quota
  /// furthest over its share gives back one row at a time. A registered quota
  /// gives back by asking its owner for the bytes still needed. Leased rows
  /// are never candidates; when only leased rows remain the store stays over
  /// budget until a lease is released.
  ///
  /// The plan is built from one listing of the index, so a pass costs
  /// O(n log n) whatever the number of victims.
  Future<int> _trimCapacity({List<BytesCacheKey>? evicted}) async {
    final limits = retention.limits;
    final usage = <String, _QuotaUsage>{};
    _QuotaUsage usageOf(String name) => usage.putIfAbsent(
      name,
      () => _QuotaUsage(_quotas[name] ?? BytesQuota(name)),
    );
    var totalBytes = 0;
    var totalEntries = 0;
    // A payload several keys read (an alias) counts once, against the quota
    // of the first row seen, and is freed only with its last reader.
    final readers = <BytesCacheKey, int>{};
    final holder = <BytesCacheKey, _QuotaUsage>{};
    for (final record in await _index.values()) {
      final quota = usageOf(record.quota);
      final payload = record.payload;
      final first = !readers.containsKey(payload);
      readers.update(payload, (n) => n + 1, ifAbsent: () => 1);
      if (first) {
        holder[payload] = quota;
        totalBytes += record.byteLength;
      }
      quota.count(
        record,
        countsBytes: first,
        isCandidate: !_leases.containsKey(payload),
      );
      totalEntries++;
    }
    for (final registered in _registered.values) {
      usageOf(registered.quota.name).registered = registered;
      totalBytes += registered.usedBytes;
    }
    for (final quota in usage.values) {
      quota.candidates.sort((a, b) => _lastUse(a).compareTo(_lastUse(b)));
    }

    final victims = <BytesRecord>[];
    Future<void> take(_QuotaUsage quota, {required int bytesNeeded}) async {
      if (quota.hasRows) {
        final victim = quota.takeOldest();
        totalEntries--;
        victims.add(victim);
        final left = readers.update(victim.payload, (n) => n - 1);
        if (left == 0) {
          holder[victim.payload]!.freeBytes(victim.byteLength);
          totalBytes -= victim.byteLength;
        }
        return;
      }
      final freed = await _askOwner(quota, bytesNeeded);
      totalBytes -= freed;
    }

    for (final quota in usage.values) {
      while (quota.isOverOwnLimits && quota.hasCandidates) {
        await take(quota, bytesNeeded: quota.bytesOverOwnLimit);
      }
    }

    int bytesOverBudget() => switch (limits.maxBytes) {
      final max? => totalBytes - max,
      null => 0,
    };
    bool entriesOverBudget() => switch (limits.maxEntries) {
      final max? => totalEntries > max,
      null => false,
    };

    while (bytesOverBudget() > 0 || entriesOverBudget()) {
      // Owners free bytes, not rows: they only help a byte overrun.
      final ownersHelp = bytesOverBudget() > 0;
      final shareOf = limits.maxBytes ?? totalBytes;
      _QuotaUsage? pick;
      for (final quota in usage.values) {
        if (!(quota.hasRows || (ownersHelp && quota.canAskOwner))) continue;
        if (pick == null) {
          pick = quota;
          continue;
        }
        final pressure = quota.pressure(shareOf);
        final best = pick.pressure(shareOf);
        if (pressure > best || (pressure == best && _olderFirst(quota, pick))) {
          pick = quota;
        }
      }
      if (pick == null) break;
      await take(pick, bytesNeeded: bytesOverBudget());
    }

    var freed = 0;
    for (final victim in victims) {
      final stillRead = readers[victim.payload]! > 0;
      if (!stillRead) freed += victim.byteLength;
      evicted?.add(victim.key);
      await _deleteBoth(victim.key, payloadStillRead: stillRead);
    }
    return freed;
  }

  /// Tie-break between equally pressed quotas: an owner's files (no last-use
  /// known here) go first, else the older least recently used row.
  bool _olderFirst(_QuotaUsage quota, _QuotaUsage than) =>
      switch ((quota.hasRows, than.hasRows)) {
        (false, _) => true,
        (true, false) => false,
        (true, true) => _lastUse(quota.oldest).isBefore(_lastUse(than.oldest)),
      };

  /// Asks [quota]'s owner for [bytes]; an owner that throws or frees nothing
  /// is not asked again in this pass.
  Future<int> _askOwner(_QuotaUsage quota, int bytes) async {
    final registered = quota.registered!;
    var freed = 0;
    try {
      freed = await registered.evict(bytes);
    } on Object catch (error, stackTrace) {
      BytesDiagnostics.current.report(
        BytesLogEvent(
          level: BytesLogLevel.error,
          message:
              'bytes store: quota ${registered.quota.name} failed to evict: '
              '$error',
          op: BytesLogOp.quotaEvict,
          stackTrace: stackTrace,
        ),
      );
    }
    quota.ownerFreed(freed);
    return freed;
  }
}

/// One quota's usage and eviction candidates while a trim pass plans.
final class _QuotaUsage {
  _QuotaUsage(this.quota);

  final BytesQuota quota;
  int _rowBytes = 0;
  int entries = 0;

  /// Owner of files counted against this quota, when one registered.
  RegisteredQuota? registered;
  var _ownerSpent = false;

  /// Unleased rows, least recently used first once sorted.
  final List<BytesRecord> candidates = [];
  var _next = 0;

  int get bytes => _rowBytes + (registered?.usedBytes ?? 0);

  void count(
    BytesRecord record, {
    required bool countsBytes,
    required bool isCandidate,
  }) {
    if (countsBytes) _rowBytes += record.byteLength;
    entries++;
    if (isCandidate) candidates.add(record);
  }

  void freeBytes(int byteLength) => _rowBytes -= byteLength;

  bool get hasRows => _next < candidates.length;

  bool get canAskOwner =>
      registered != null && !_ownerSpent && registered!.usedBytes > 0;

  bool get hasCandidates => hasRows || canAskOwner;

  BytesRecord get oldest => candidates[_next];

  int get bytesOverOwnLimit => switch (quota.maxBytes) {
    final max? => bytes - max,
    null => 0,
  };

  bool get isOverOwnLimits =>
      bytesOverOwnLimit > 0 ||
      switch (quota.maxEntries) {
        final max? => entries > max,
        null => false,
      };

  /// Share of its own budget in use; a quota without one is measured against
  /// [fallback], the store's budget.
  double pressure(int fallback) =>
      bytes / (quota.maxBytes ?? (fallback > 0 ? fallback : 1));

  /// Next victim; its bytes leave the plan through [freeBytes] once no other
  /// row reads its payload.
  BytesRecord takeOldest() {
    final victim = candidates[_next++];
    entries--;
    return victim;
  }

  /// [RegisteredQuota.evict] already took [freed] off the owner's usage.
  void ownerFreed(int freed) {
    if (freed <= 0) _ownerSpent = true;
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
final class MemoryBytesCache implements IBytesStore {
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
  Future<Uint8List?> read(BytesCacheKey key) async =>
      (await readRich(key))?.bytes;

  /// Always null: a memory store keeps no files.
  @override
  Future<FileLease?> leaseFile(BytesCacheKey key) async => null;

  final Set<String> _registered = {};

  /// [server] gets an entry over the same [Uint8List] as [local]: no copy.
  @override
  Future<bool> alias(BytesCacheKey local, BytesCacheKey server) async {
    final source = _entries[local];
    final now = _clock();
    if (source == null ||
        source.bytes.isEmpty ||
        retention.isExpired(source.accessedAt, now: now)) {
      return false;
    }
    if (local == server) return true;
    _entries[server] = _MemoryEntry(
      bytes: source.bytes,
      writtenAt: now,
      accessedAt: now,
    );
    return true;
  }

  @override
  Future<void> release(BytesCacheKey local) => evict(local);

  /// Accepts the registration but never asks the owner: a memory store keeps
  /// no disk budget for another owner's files to count against.
  @override
  RegisteredQuota registerQuota(
    BytesQuota quota, {
    required QuotaEvictor onEvict,
  }) {
    if (!_registered.add(quota.name)) {
      throw StateError('Quota ${quota.name} is already registered');
    }
    return RegisteredQuota(
      quota: quota,
      onEvict: onEvict,
      onUnregister: () => _registered.remove(quota.name),
    );
  }

  @override
  bool contains(BytesCacheKey key) => switch (_entries[key]) {
    final entry? =>
      entry.bytes.isNotEmpty &&
          !retention.isExpired(entry.accessedAt, now: _clock()),
    null => false,
  };

  /// Same miss rules as [read], plus timestamps and [HttpCacheMeta].
  @override
  Future<BytesRichHit?> readRich(BytesCacheKey key) async {
    if (_entries[key] case final entry?) {
      final now = _clock();
      if (retention.isExpired(entry.accessedAt, now: now)) {
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
  /// [quota] is ignored: a memory store keeps one budget.
  @override
  Future<void> write(
    BytesCacheKey key,
    Uint8List bytes, {
    HttpCacheMeta? httpCacheMeta,
    BytesQuota? quota,
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

    if (retention.limits.maxAge != null) {
      final expired = _entries.entries
          .where((e) => retention.isExpired(e.value.accessedAt, now: now))
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
      if (limits.maxEntries case final maxEntries?
          when _entries.length > maxEntries) {
        return true;
      }
      if (limits.maxBytes case final maxBytes?) {
        final total = _entries.values.fold<int>(
          0,
          (s, e) => s + e.bytes.length,
        );
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
    BytesQuota? quota,
  }) async {}

  /// Nothing to remove.
  @override
  Future<void> evict(BytesCacheKey key) async {}

  /// Returns an empty [BytesPruneReport].
  @override
  Future<BytesPruneReport> prune() async =>
      const BytesPruneReport(evictedKeys: [], freedBytes: 0);

  /// No resources to release. Idempotent so tearDown can call [close] uniformly.
  @override
  Future<void> close() async {}
}

/// Process-wide [IBytesCache] and the way to open the durable store.
abstract final class BytesCache {
  /// Shared instance. [NoOpBytesCache] until [configure] or [debugShared].
  static IBytesCache shared() =>
      debugShared ?? _shared ?? const NoOpBytesCache();

  static IBytesCache? _shared;

  /// Opens the environment-specific durable store.
  ///
  /// [retention] is the store's whole budget; [quotas] share it (see
  /// [BytesQuota]).
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
  static Future<IBytesStore> open({
    String? directory,
    BytesRetention retention = BytesRetention.standard,
    Iterable<BytesQuota> quotas = BytesQuota.standard,
    DateTime Function()? clock,
    BytesDiagnostics diagnostics = const BytesDiagnostics.silent(),
    bool throwOnOpenFailure = false,
  }) async {
    BytesDiagnostics.current = diagnostics;
    try {
      return await environment_specific.$openBytesCache(
        directory: directory,
        retention: retention,
        quotas: quotas,
        clock: clock,
      );
    } on Object catch (error, stackTrace) {
      // Missing VM directory is ArgumentError (host wiring), not storage failure.
      if (error case ArgumentError()) rethrow;
      if (throwOnOpenFailure) rethrow;
      diagnostics.report(
        BytesLogEvent(
          level: BytesLogLevel.warning,
          message:
              'image bytes cache: open failed, using in-memory store: $error',
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
    for (final hook in List<FutureOr<void> Function()>.of(
      _afterResetSharedHooks,
    )) {
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
