import 'dart:convert';

import 'package:http_bytes_cache/src/bytes_cache.dart';

/// Records ↔ UTF-8 JSON bytes for the durable index document.
///
/// Shape: `{"v":1,"e":{"<key>":{"w":ms,"a":ms,"n":byteLength,"h"?:{…}}}}`.
/// Optional `h` is [HttpCacheMeta] on the wire (`et`, `lm`, `d`, `x`,
/// `cc`, `ag`, `lv`). Missing `h`, or missing keys inside it, decode as null
/// meta. Old documents stay valid. Unknown [version] or a broken structure
/// throws [FormatException] so open can wipe.
final class BytesIndexDocumentCodec extends Codec<Map<String, BytesRecord>, List<int>> {
  /// Shared codec instance for durable index adapters.
  const BytesIndexDocumentCodec();

  /// Wire version for the durable index document (VM file and web meta cache).
  static const int version = 1;

  static const _jsonCodec = _BytesIndexDocumentJsonCodec();

  static const _utf8Codec = Utf8Codec();
  static const _jsonEncoder = JsonEncoder();
  static const _jsonDecoder = JsonDecoder();

  @override
  Converter<Map<String, BytesRecord>, List<int>> get encoder =>
      _jsonCodec.encoder.fuse(_jsonEncoder).fuse(_utf8Codec.encoder);

  @override
  Converter<List<int>, Map<String, BytesRecord>> get decoder =>
      _utf8Codec.decoder.fuse(_jsonDecoder).fuse(_jsonCodec.decoder);
}

/// Records ↔ JSON-compatible object (internal half of the bytes codec).
final class _BytesIndexDocumentJsonCodec extends Codec<Map<String, BytesRecord>, Object?> {
  const _BytesIndexDocumentJsonCodec();

  @override
  Converter<Map<String, BytesRecord>, Object?> get encoder => const _BytesIndexDocumentEncoder();

  @override
  Converter<Object?, Map<String, BytesRecord>> get decoder => const _BytesIndexDocumentDecoder();
}

final class _BytesIndexDocumentEncoder extends Converter<Map<String, BytesRecord>, Object?> {
  const _BytesIndexDocumentEncoder();

  @override
  Object? convert(Map<String, BytesRecord> input) => {
    'v': BytesIndexDocumentCodec.version,
    'e': {
      for (final MapEntry(:key, :value) in input.entries)
        key: {
          'w': value.writtenAt.toUtc().millisecondsSinceEpoch,
          'a': value.accessedAt.toUtc().millisecondsSinceEpoch,
          'n': value.byteLength,
          if (value.httpCacheMeta case final meta? when !meta.isEmpty) 'h': _encodeHttpMeta(meta),
        },
    },
  };

  static Map<String, Object> _encodeHttpMeta(HttpCacheMeta meta) => {
    'et': ?meta.etag,
    'lm': ?meta.lastModified,
    'd': ?meta.date?.toUtc().millisecondsSinceEpoch,
    'x': ?meta.expires?.toUtc().millisecondsSinceEpoch,
    'cc': ?meta.cacheControl,
    'ag': ?meta.age?.inMilliseconds,
    'lv': ?meta.lastValidatedAt?.toUtc().millisecondsSinceEpoch,
  };
}

final class _BytesIndexDocumentDecoder extends Converter<Object?, Map<String, BytesRecord>> {
  const _BytesIndexDocumentDecoder();

  @override
  Map<String, BytesRecord> convert(Object? input) => switch (input) {
    {
      'v': final Object? version,
      'e': final Map entries,
    }
        when version == BytesIndexDocumentCodec.version =>
      {
        for (final MapEntry(:key, :value) in entries.entries)
          key.toString(): _recordFromEntry(
            BytesCacheKey(key.toString()),
            value,
          ),
      },
    {'v': final Object? version} when version != BytesIndexDocumentCodec.version => throw FormatException(
      'image bytes index: unsupported version $version',
    ),
    _ => throw const FormatException(
      'image bytes index: root is not a versioned entries object',
    ),
  };

  static BytesRecord _recordFromEntry(BytesCacheKey key, Object? raw) => switch (raw) {
    {
          'w': final int writtenAtMs,
          'a': final int accessedAtMs,
          'n': final int byteLength,
        } &&
        final Map map =>
      BytesRecord(
        key: key,
        writtenAt: DateTime.fromMillisecondsSinceEpoch(
          writtenAtMs,
          isUtc: true,
        ),
        accessedAt: DateTime.fromMillisecondsSinceEpoch(
          accessedAtMs,
          isUtc: true,
        ),
        byteLength: byteLength,
        httpCacheMeta: _httpMetaFrom(map['h']),
      ),
    _ => throw const FormatException(
      'image bytes index: invalid entry fields',
    ),
  };

  /// Missing or null `h` becomes null meta. Wrong `h` type or field types throw
  /// [FormatException] so open can wipe instead of keeping half-parsed validators.
  static HttpCacheMeta? _httpMetaFrom(Object? raw) => switch (raw) {
    null => null,
    final Map map => _httpMetaFromMap(map),
    _ => throw const FormatException('image bytes index: invalid HTTP cache meta'),
  };

  static HttpCacheMeta? _httpMetaFromMap(Map map) {
    final etag = switch (map['et']) {
      null => null,
      final String s => s,
      _ => throw const FormatException('image bytes index: invalid etag'),
    };
    final lastModified = switch (map['lm']) {
      null => null,
      final String s => s,
      _ => throw const FormatException('image bytes index: invalid lastModified'),
    };
    final date = _optionalUtcMs(map['d'], 'date');
    final expires = _optionalUtcMs(map['x'], 'expires');
    final cacheControl = switch (map['cc']) {
      null => null,
      final String s => s,
      _ => throw const FormatException('image bytes index: invalid cacheControl'),
    };
    final age = switch (map['ag']) {
      null => null,
      final int ms => Duration(milliseconds: ms),
      _ => throw const FormatException('image bytes index: invalid age'),
    };
    final lastValidatedAt = _optionalUtcMs(map['lv'], 'lastValidatedAt');
    final meta = HttpCacheMeta(
      etag: etag,
      lastModified: lastModified,
      date: date,
      expires: expires,
      cacheControl: cacheControl,
      age: age,
      lastValidatedAt: lastValidatedAt,
    );
    return meta.isEmpty ? null : meta;
  }

  static DateTime? _optionalUtcMs(Object? raw, String field) => switch (raw) {
    null => null,
    final int ms => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true),
    _ => throw FormatException('image bytes index: invalid $field'),
  };
}
