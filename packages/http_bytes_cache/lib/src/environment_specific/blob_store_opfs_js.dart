import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:http_bytes_cache/src/bytes_cache.dart';
import 'package:http_bytes_cache/src/bytes_web_keys.dart';
import 'package:web/web.dart' as web;

/// Web OPFS payload half: one file per [BytesCacheKey] under a package directory.
///
/// Used for large bodies routed by the composite web blob store (Cache API stays
/// for smaller payloads). File names are [BytesCacheKey.value] (already
/// filename-safe). Writes use [web.FileSystemFileHandle.createWritable], which
/// replaces the visible file only when the stream closes. A crash mid-write
/// does not leave a truncated hit. [reclaimOrphans] walks directory keys via
/// the async iterator (missing from package:web bindings). [close] drops the
/// directory handle.
final class BytesBlobStore$Opfs$JS implements IBytesBlobStore {
  BytesBlobStore$Opfs$JS._(this._directory);

  web.FileSystemDirectoryHandle? _directory;
  var _closed = false;

  /// Opens (or creates) [BytesWebKeys.opfsBlobsDirectoryName] under OPFS root.
  static Future<BytesBlobStore$Opfs$JS> open() async {
    final root = await web.window.navigator.storage.getDirectory().toDart;
    final directory = await root
        .getDirectoryHandle(
          BytesWebKeys.opfsBlobsDirectoryName,
          web.FileSystemGetDirectoryOptions(create: true),
        )
        .toDart;
    return BytesBlobStore$Opfs$JS._(directory);
  }

  @override
  Future<Uint8List?> read(BytesCacheKey key, {int? knownByteLength}) async {
    final directory = _ensureOpen();
    try {
      final handle = await directory.getFileHandle(key.value).toDart;
      final file = await handle.getFile().toDart;
      final jsBuffer = await file.arrayBuffer().toDart;
      return jsBuffer.toDart.asUint8List();
    } on Object catch (error) {
      if (_$isMissingEntry(error)) return null;
      rethrow;
    }
  }

  @override
  Future<void> write(BytesCacheKey key, Uint8List bytes) async {
    final directory = _ensureOpen();
    final handle = await directory
        .getFileHandle(
          key.value,
          web.FileSystemGetFileOptions(create: true),
        )
        .toDart;
    final writable = await handle.createWritable().toDart;
    await writable.write(bytes.toJS).toDart;
    await writable.close().toDart;
  }

  @override
  Future<void> delete(BytesCacheKey key) async {
    final directory = _ensureOpen();
    try {
      await directory.removeEntry(key.value).toDart;
    } on Object {
      // Missing file is a no-op, same as the Cache / VM blob halves.
    }
  }

  /// Deletes OPFS files whose name is not in [indexedKeys].
  Future<void> reclaimOrphans(Set<String> indexedKeys) async {
    final directory = _ensureOpen();
    await for (final name in _$directoryKeys(directory)) {
      if (indexedKeys.contains(name)) continue;
      try {
        await directory.removeEntry(name).toDart;
      } on Object {
        // Entry may vanish between list and delete.
      }
    }
  }

  /// Deletes every file in the package OPFS directory.
  Future<void> wipeAll() async {
    final directory = _ensureOpen();
    await for (final name in _$directoryKeys(directory)) {
      try {
        await directory.removeEntry(name).toDart;
      } on Object {
        // Best-effort wipe after corrupt index recovery.
      }
    }
  }

  /// Drops the directory handle. Idempotent.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _directory = null;
  }

  web.FileSystemDirectoryHandle _ensureOpen() {
    if (_closed) {
      throw StateError(r'BytesBlobStore$Opfs$JS is closed');
    }
    return switch (_directory) {
      final directory? => directory,
      null => throw StateError(r'BytesBlobStore$Opfs$JS is closed'),
    };
  }
}

/// package:web omits async iterable helpers on [web.FileSystemDirectoryHandle].
Stream<String> _$directoryKeys(web.FileSystemDirectoryHandle directory) async* {
  final iterator = (directory as JSObject).callMethod('keys'.toJS);
  if (iterator == null) return;
  final jsIterator = iterator as JSObject;
  while (true) {
    final next = await jsIterator.callMethod<JSPromise<JSObject>>('next'.toJS).toDart;
    final done = next.getProperty('done'.toJS);
    if (done case final JSBoolean flag when flag.toDart) break;
    yield switch (next.getProperty('value'.toJS)) {
      final JSString s => s.toDart,
      _ => throw StateError('OPFS directory iterator yielded non-string key'),
    };
  }
}

/// True when [error] is a missing-entry miss (not a hard IO fault).
bool _$isMissingEntry(Object error) => switch (error) {
  web.DOMException(name: 'NotFoundError') => true,
  final JSObject box => switch (box.getProperty('name'.toJS)) {
    final JSString name when name.toDart == 'NotFoundError' => true,
    _ => false,
  },
  _ => false,
};
