import 'dart:convert';

import 'package:http_bytes_cache/src/bytes_cache.dart';
import 'package:http_bytes_cache/src/bytes_index_document.dart';
import 'package:http_bytes_cache/src/bytes_web_keys.dart';
import 'package:test/test.dart';

/// Builds UTF-8 JSON bytes without the domain index codec (fixtures only).
List<int> _jsonObjectBytes(Object? value) => const JsonEncoder().fuse(const Utf8Encoder()).convert(value);

void main() {
  group('BytesIndexDocumentCodec', () {
    const codec = BytesIndexDocumentCodec();

    test('round-trips records', () {
      final written = DateTime.utc(2024, 1, 2, 3, 4, 5);
      final accessed = DateTime.utc(2024, 1, 2, 3, 5, 0);
      final input = {
        'logo': BytesRecord(
          key: const BytesCacheKey('logo'),
          writtenAt: written,
          accessedAt: accessed,
          byteLength: 12,
        ),
      };

      final wire = codec.encode(input);
      final decoded = codec.decode(wire);

      expect(decoded.keys, ['logo']);
      expect(decoded['logo']!.byteLength, 12);
      expect(decoded['logo']!.writtenAt, written);
      expect(decoded['logo']!.accessedAt, accessed);
      expect(decoded['logo']!.httpCacheMeta, isNull);
    });

    test('round-trips optional HTTP cache meta', () {
      final written = DateTime.utc(2024, 1, 2, 3, 4, 5);
      final accessed = DateTime.utc(2024, 1, 2, 3, 5, 0);
      final date = DateTime.utc(2024, 1, 2, 3, 0);
      final expires = DateTime.utc(2024, 1, 3);
      final lastValidated = DateTime.utc(2024, 1, 2, 3, 6);
      final meta = HttpCacheMeta(
        etag: '"abc"',
        lastModified: 'Wed, 21 Oct 2015 07:28:00 GMT',
        date: date,
        expires: expires,
        cacheControl: 'max-age=3600',
        age: const Duration(seconds: 12),
        lastValidatedAt: lastValidated,
      );
      final input = {
        'logo': BytesRecord(
          key: const BytesCacheKey('logo'),
          writtenAt: written,
          accessedAt: accessed,
          byteLength: 12,
          httpCacheMeta: meta,
        ),
      };

      final decoded = codec.decode(codec.encode(input));
      final hit = decoded['logo']!;

      expect(hit.httpCacheMeta?.etag, '"abc"');
      expect(hit.httpCacheMeta?.lastModified, 'Wed, 21 Oct 2015 07:28:00 GMT');
      expect(hit.httpCacheMeta?.date, date);
      expect(hit.httpCacheMeta?.expires, expires);
      expect(hit.httpCacheMeta?.cacheControl, 'max-age=3600');
      expect(hit.httpCacheMeta?.age, const Duration(seconds: 12));
      expect(hit.httpCacheMeta?.lastValidatedAt, lastValidated);
    });

    test('decodes pre-ETag entries without HTTP meta fields as null meta', () {
      final wire = _jsonObjectBytes({
        'v': 1,
        'e': {
          'logo': {
            'w': DateTime.utc(2024, 1, 2).millisecondsSinceEpoch,
            'a': DateTime.utc(2024, 1, 3).millisecondsSinceEpoch,
            'n': 4,
          },
        },
      });

      final decoded = codec.decode(wire);

      expect(decoded['logo']!.byteLength, 4);
      expect(decoded['logo']!.httpCacheMeta, isNull);
    });

    test('decodes partial HTTP meta with missing keys as null fields', () {
      final wire = _jsonObjectBytes({
        'v': 1,
        'e': {
          'logo': {
            'w': DateTime.utc(2024, 1, 2).millisecondsSinceEpoch,
            'a': DateTime.utc(2024, 1, 3).millisecondsSinceEpoch,
            'n': 4,
            'h': {'et': '"only-etag"'},
          },
        },
      });

      final meta = codec.decode(wire)['logo']!.httpCacheMeta;

      expect(meta?.etag, '"only-etag"');
      expect(meta?.lastModified, isNull);
      expect(meta?.cacheControl, isNull);
      expect(meta?.age, isNull);
    });

    test('rejects unsupported version', () {
      expect(
        () => codec.decode(
          _jsonObjectBytes({
            'v': 99,
            'e': <String, Object?>{},
          }),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects malformed root', () {
      expect(
        () => codec.decode(_jsonObjectBytes({'nope': true})),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('BytesWebKeys', () {
    test('blobUrl encodes key and round-trips via keyValueFromBlobUrl', () {
      const key = BytesCacheKey('host_logo_abcdef123456');
      final url = BytesWebKeys.blobUrl(key);
      expect(url, startsWith('https://image-bytes.invalid/v1/blob/'));
      expect(BytesWebKeys.keyValueFromBlobUrl(url), key.value);
    });

    test('keyValueFromBlobUrl ignores foreign URLs', () {
      expect(
        BytesWebKeys.keyValueFromBlobUrl('https://cdn.example/logo.png'),
        isNull,
      );
      expect(
        BytesWebKeys.keyValueFromBlobUrl(BytesWebKeys.indexDocumentUrl),
        isNull,
      );
    });

    test('cache names stay distinct so meta scan never loads payloads', () {
      expect(
        BytesWebKeys.indexCacheName,
        isNot(BytesWebKeys.blobsCacheName),
      );
    });

    test('OPFS directory name is stable and distinct from the index Cache', () {
      expect(BytesWebKeys.opfsBlobsDirectoryName, 'image_bytes_blobs_v1');
      expect(
        BytesWebKeys.opfsBlobsDirectoryName,
        isNot(BytesWebKeys.indexCacheName),
      );
    });
  });
}
