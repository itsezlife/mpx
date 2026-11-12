import 'dart:typed_data';

import 'package:http_bytes_cache/src/bytes_cache.dart';
import 'package:http_bytes_cache/src/bytes_diagnostics.dart';
import 'package:http_bytes_cache/src/bytes_index_document.dart';
import 'package:http_bytes_cache/src/environment_specific/blob_store_file_vm.dart';
import 'package:path/path.dart' as p;

const BytesIndexDocumentCodec _$indexCodec = BytesIndexDocumentCodec();

/// VM metadata half of [IndexedBytesCache]: one versioned JSON document.
///
/// Kept separate from blobs so prune/LRU can scan timestamps and sizes without
/// loading every payload. [get] / [put] / [delete] / [values] mutate the RAM
/// mirror only; [commit] writes the durable document through
/// [BytesBlobStore$File$VM] (same isolate worker as payloads).
///
/// Wire shape is owned by [BytesIndexDocumentCodec]. Bad JSON or an
/// unknown version deletes the document and runs [onWipe]: remote bytes
/// are safe to drop, so wipe-on-unrecognized beats a crash loop or a
/// half-migrated schema.
final class BytesIndex$File$VM implements IBytesIndex {
  BytesIndex$File$VM._({
    required this.directory,
    required BytesBlobStore$File$VM io,
    required Map<String, BytesRecord> records,
  }) : _io = io,
       _records = records;

  /// Cache root shared with [BytesBlobStore$File$VM].
  final String directory;

  final BytesBlobStore$File$VM _io;
  final Map<String, BytesRecord> _records;

  String get _path => p.join(directory, BytesBlobStore$File$VM.indexFileName);

  /// Loads the index, or starts empty after wipe recovery.
  ///
  /// [onWipe] clears sibling payload files when the document cannot be trusted.
  static Future<BytesIndex$File$VM> open({
    required String directory,
    required BytesBlobStore$File$VM io,
    required Future<void> Function() onWipe,
  }) async {
    final path = p.join(directory, BytesBlobStore$File$VM.indexFileName);
    return switch (await io.readPath(path)) {
      null => BytesIndex$File$VM._(
        directory: directory,
        io: io,
        records: {},
      ),
      final raw => await _openDecoded(
        directory: directory,
        io: io,
        path: path,
        raw: raw,
        onWipe: onWipe,
      ),
    };
  }

  static Future<BytesIndex$File$VM> _openDecoded({
    required String directory,
    required BytesBlobStore$File$VM io,
    required String path,
    required Uint8List raw,
    required Future<void> Function() onWipe,
  }) async {
    try {
      return BytesIndex$File$VM._(
        directory: directory,
        io: io,
        records: _$indexCodec.decode(raw),
      );
    } on Object catch (error, stackTrace) {
      BytesDiagnostics.current.report(
        BytesLogEvent(
          level: BytesLogLevel.warning,
          message: 'image bytes index: wiping corrupt or unrecognized file document: $error',
          op: BytesLogOp.indexWipe,
          stackTrace: stackTrace,
        ),
      );
      await io.deletePath(path);
      await onWipe();
      return BytesIndex$File$VM._(
        directory: directory,
        io: io,
        records: {},
      );
    }
  }

  Future<void> _persist() async {
    final encoded = _$indexCodec.encode(_records);
    final bytes = switch (encoded) {
      final Uint8List list => list,
      final list => Uint8List.fromList(list),
    };
    await _io.writePathAtomic(_path, bytes);
  }

  @override
  Future<BytesRecord?> get(BytesCacheKey key) async => _records[key.value];

  @override
  Future<void> put(BytesRecord record) async {
    _records[record.key.value] = record;
  }

  @override
  Future<void> delete(BytesCacheKey key) async {
    _records.remove(key.value);
  }

  @override
  Future<Iterable<BytesRecord>> values() async => _records.values;

  /// Atomic snapshot of the RAM mirror. Called once per mutate epoch.
  @override
  Future<void> commit() => _persist();
}
