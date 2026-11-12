import 'dart:js_interop';
import 'dart:typed_data';

import 'package:http_bytes_cache/src/bytes_cache.dart';
import 'package:http_bytes_cache/src/bytes_diagnostics.dart';
import 'package:http_bytes_cache/src/bytes_index_document.dart';
import 'package:http_bytes_cache/src/bytes_web_keys.dart';
import 'package:web/web.dart' as web;

const BytesIndexDocumentCodec _$indexCodec = BytesIndexDocumentCodec();

/// Web metadata half of [IndexedBytesCache]: one Cache API JSON document.
///
/// A dedicated Cache ([BytesWebKeys.indexCacheName]) holds the same
/// versioned document shape as the VM file index
/// ([BytesIndexDocumentCodec]). [get] / [put] / [delete] / [values] touch
/// the RAM mirror only; [commit] rewrites the Cache document. Prune and LRU
/// scan [_records] without reading payload Responses from the blob Cache.
///
/// Unrecognized or corrupt documents delete the meta entry and run [onWipe]
/// (blob Cache wipe). Remote bytes are safe to drop.
final class BytesIndex$Cache$JS implements IBytesIndex {
  BytesIndex$Cache$JS._({
    required web.Cache cache,
    required Map<String, BytesRecord> records,
  }) : _cache = cache,
       _records = records;

  web.Cache? _cache;
  final Map<String, BytesRecord> _records;
  var _closed = false;

  /// Opens the meta Cache and loads the document, or starts empty after wipe.
  static Future<BytesIndex$Cache$JS> open({
    required Future<void> Function() onWipe,
  }) async {
    final cache = await web.window.caches.open(BytesWebKeys.indexCacheName).toDart;
    final match = await cache.match(BytesWebKeys.indexDocumentUrl.toJS).toDart;
    return switch (match) {
      null => BytesIndex$Cache$JS._(
        cache: cache,
        records: {},
      ),
      final response => await _openDecoded(
        cache: cache,
        response: response,
        onWipe: onWipe,
      ),
    };
  }

  static Future<BytesIndex$Cache$JS> _openDecoded({
    required web.Cache cache,
    required web.Response response,
    required Future<void> Function() onWipe,
  }) async {
    try {
      final raw = await _$responseBytes(response);
      return BytesIndex$Cache$JS._(
        cache: cache,
        records: _$indexCodec.decode(raw),
      );
    } on Object catch (error, stackTrace) {
      BytesDiagnostics.current.report(
        BytesLogEvent(
          level: BytesLogLevel.warning,
          message: 'image bytes index: wiping corrupt or unrecognized Cache document: $error',
          op: BytesLogOp.indexWipe,
          stackTrace: stackTrace,
        ),
      );
      await cache.delete(BytesWebKeys.indexDocumentUrl.toJS).toDart;
      await onWipe();
      return BytesIndex$Cache$JS._(
        cache: cache,
        records: {},
      );
    }
  }

  Future<void> _persist() async {
    final cache = _ensureOpen();
    final bytes = Uint8List.fromList(_$indexCodec.encode(_records));
    await cache
        .put(
          BytesWebKeys.indexDocumentUrl.toJS,
          web.Response(bytes.toJS),
        )
        .toDart;
  }

  /// Releases the Cache handle. Idempotent.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _cache = null;
  }

  web.Cache _ensureOpen() {
    if (_closed) {
      throw StateError(r'BytesIndex$Cache$JS is closed');
    }
    return switch (_cache) {
      final cache? => cache,
      null => throw StateError(r'BytesIndex$Cache$JS is closed'),
    };
  }

  @override
  Future<BytesRecord?> get(BytesCacheKey key) async => _records[key.value];

  @override
  Future<void> put(BytesRecord record) async {
    _ensureOpen();
    _records[record.key.value] = record;
  }

  @override
  Future<void> delete(BytesCacheKey key) async {
    _ensureOpen();
    _records.remove(key.value);
  }

  @override
  Future<Iterable<BytesRecord>> values() async => _records.values;

  /// Persists the RAM mirror once per mutate epoch.
  @override
  Future<void> commit() => _persist();
}

Future<Uint8List> _$responseBytes(web.Response response) async {
  final jsBytes = await response.bytes().toDart;
  return jsBytes.toDart;
}
