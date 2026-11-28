import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:mpx_transfer/src/job/transfer_id.dart';
import 'package:mpx_transfer/src/journal/journal_store.dart';
import 'package:mpx_transfer/src/journal/upload_source_copies.dart';
import 'package:web/web.dart' as web;

/// The journal's directory in the origin private file system, at its root
/// beside the bytes cache's own directory.
///
/// Web only.
abstract final class JournalStorage$Opfs$JS {
  /// The directory's name at the OPFS root by default.
  static const String defaultName = 'mpx_transfer';

  /// Opens (or makes) directory [name] at the OPFS root, with a journal
  /// store and the upload source copies in it.
  ///
  /// Throws when the page has no OPFS (an insecure context, a browser
  /// without it, a private window that refuses it); the caller falls back
  /// to memory. [root] gives the OPFS root, for tests.
  static Future<(JournalStore$Opfs$JS, UploadSourceCopies$Opfs$JS)> open({
    String name = defaultName,
    Future<web.FileSystemDirectoryHandle> Function()? root,
  }) async {
    final top = await (root ?? _opfsRoot)();
    final directory = await top
        .getDirectoryHandle(
          name,
          web.FileSystemGetDirectoryOptions(create: true),
        )
        .toDart;
    final copies = await UploadSourceCopies$Opfs$JS.open(directory);
    return (JournalStore$Opfs$JS(directory), copies);
  }

  /// A short code for [error], thrown while opening, for diagnostics.
  static String errorCode(Object error) => _errorCode(error);

  static Future<web.FileSystemDirectoryHandle> _opfsRoot() =>
      web.window.navigator.storage.getDirectory().toDart;
}

/// A [JournalStore] in two OPFS files of [directory]: `<name>.snapshot`
/// and `<name>.log`, `journal` unless another [name] is given (the reuse
/// table's store sits beside the journal's).
///
/// Written on the main thread, which has no synchronous access handle, so
/// every write goes through a writable stream. A stream's bytes become the
/// file only when it closes, all at once: an append is kept whole or not
/// at all, and a snapshot is replaced whole or not at all.
final class JournalStore$Opfs$JS implements JournalStore {
  /// A store in [directory].
  JournalStore$Opfs$JS(this.directory, {this.name = 'journal'});

  /// The directory the two files are in.
  final web.FileSystemDirectoryHandle directory;

  /// What the two files are named before their extension.
  final String name;

  @override
  JournalStoreKind get kind => JournalStoreKind.opfs;

  @override
  Future<Uint8List> read(JournalBlob blob) async {
    final web.FileSystemFileHandle handle;
    try {
      handle = await directory.getFileHandle(_nameOf(blob)).toDart;
    } on Object catch (error) {
      if (_isMissing(error)) return Uint8List(0);
      rethrow;
    }
    final file = await handle.getFile().toDart;
    return (await file.arrayBuffer().toDart).toDart.asUint8List();
  }

  @override
  Future<void> append(Uint8List bytes) async {
    final handle = await _create(_nameOf(JournalBlob.log));
    final size = (await handle.getFile().toDart).size;
    await _write(handle, bytes.toJS, keep: true, at: size);
  }

  @override
  Future<void> replace({
    required Uint8List snapshot,
    required Uint8List log,
  }) async {
    await _write(await _create(_nameOf(JournalBlob.snapshot)), snapshot.toJS);
    await _write(await _create(_nameOf(JournalBlob.log)), log.toJS);
  }

  @override
  Future<void> close() async {}

  @override
  String errorCode(Object error) => _errorCode(error);

  Future<web.FileSystemFileHandle> _create(String name) => directory
      .getFileHandle(name, web.FileSystemGetFileOptions(create: true))
      .toDart;

  String _nameOf(JournalBlob blob) => '$name.${blob.name}';
}

/// [SourceBytes] of a browser `Blob`: a file the user picked, or the copy
/// of one in OPFS.
final class SourceBytes$Blob$JS implements SourceBytes {
  /// A source of [blob].
  SourceBytes$Blob$JS(this.blob);

  /// The blob the bytes are in.
  final web.Blob blob;

  @override
  int get size => blob.size;

  @override
  Future<Uint8List> read([int start = 0, int? end]) async {
    final part = blob.slice(start, end ?? blob.size);
    return (await part.arrayBuffer().toDart).toDart.asUint8List();
  }
}

/// [UploadSourceCopies] in directory `sources` of the journal's OPFS
/// directory.
///
/// Job `<id>`'s source at index `i` is file `<id>.<i>`; file `<id>.kept`,
/// written once every source is, marks the job's copies as whole, and is
/// deleted first. Files of a job without that mark were cut short by a
/// reload and are deleted at [open].
final class UploadSourceCopies$Opfs$JS implements UploadSourceCopies {
  UploadSourceCopies$Opfs$JS._(this._directory, this._held);

  /// Opens directory `sources` of [journal] (made when missing), reads
  /// which jobs are kept and deletes what a reload cut short.
  static Future<UploadSourceCopies$Opfs$JS> open(
    web.FileSystemDirectoryHandle journal,
  ) async {
    final directory = await journal
        .getDirectoryHandle(
          'sources',
          web.FileSystemGetDirectoryOptions(create: true),
        )
        .toDart;
    final names = await _namesIn(directory).toList();
    final held = {
      for (final name in names)
        if (name.endsWith(_keptSuffix))
          TransferId.parse(name.substring(0, name.length - _keptSuffix.length)),
    };
    for (final name in names) {
      if (held.contains(TransferId.parse(_jobOf(name)))) continue;
      await _remove(directory, name);
    }
    return UploadSourceCopies$Opfs$JS._(directory, held);
  }

  static const String _keptSuffix = '.kept';

  final web.FileSystemDirectoryHandle _directory;
  final Set<TransferId> _held;

  @override
  bool holds(TransferId id) => _held.contains(id);

  @override
  Iterable<TransferId> get held => _held;

  @override
  Future<bool> copy(TransferId id, List<SourceBytes> sources) async {
    try {
      for (var index = 0; index < sources.length; index++) {
        await _write(await _create('$id.$index'), _dataOf(sources[index]));
      }
      await _write(await _create('$id$_keptSuffix'), Uint8List(0).toJS);
    } on Object {
      await _deleteFiles(id);
      rethrow;
    }
    _held.add(id);
    return true;
  }

  @override
  Future<SourceBytes?> read(TransferId id, int index) async {
    if (!_held.contains(id)) return null;
    try {
      final handle = await _directory.getFileHandle('$id.$index').toDart;
      return SourceBytes$Blob$JS(await handle.getFile().toDart);
    } on Object catch (error) {
      if (_isMissing(error)) return null;
      rethrow;
    }
  }

  @override
  Future<void> delete(TransferId id) async {
    _held.remove(id);
    await _deleteFiles(id);
  }

  @override
  String errorCode(Object error) => _errorCode(error);

  /// Deletes the mark first, so a reload in the middle of a delete finds
  /// the rest unmarked and deletes it.
  Future<void> _deleteFiles(TransferId id) async {
    await _remove(_directory, '$id$_keptSuffix');
    await for (final name in _namesIn(_directory)) {
      if (_jobOf(name) == id) await _remove(_directory, name);
    }
  }

  Future<web.FileSystemFileHandle> _create(String name) => _directory
      .getFileHandle(name, web.FileSystemGetFileOptions(create: true))
      .toDart;

  static JSAny _dataOf(SourceBytes source) => switch (source) {
    SourceBytes$Blob$JS(:final blob) => blob,
    MemorySourceBytes(:final bytes) => bytes.toJS,
    _ => throw ArgumentError.value(
      source.runtimeType,
      'source',
      'not a source the web can copy',
    ),
  };

  /// The job a file of a job belongs to: its name up to the last dot.
  static String _jobOf(String name) => switch (name.lastIndexOf('.')) {
    -1 => name,
    final dot => name.substring(0, dot),
  };

  static Future<void> _remove(
    web.FileSystemDirectoryHandle directory,
    String name,
  ) async {
    try {
      await directory.removeEntry(name).toDart;
    } on Object catch (error) {
      if (!_isMissing(error)) rethrow;
    }
  }
}

/// Writes [data] to [handle] through a writable stream, replacing the
/// file, or with [keep] writing at [at] over what is there.
///
/// The bytes become the file only at the close; a stream that fails is
/// aborted, so the file stays as it was.
Future<void> _write(
  web.FileSystemFileHandle handle,
  JSAny data, {
  bool keep = false,
  int at = 0,
}) async {
  final writable = await handle
      .createWritable(
        web.FileSystemCreateWritableOptions(keepExistingData: keep),
      )
      .toDart;
  try {
    if (at > 0) await writable.seek(at).toDart;
    await writable.write(data).toDart;
    await writable.close().toDart;
  } on Object {
    try {
      await writable.abort().toDart;
    } on Object {
      // The write already failed; that error is the one to report.
    }
    rethrow;
  }
}

/// The names in [directory]; package:web has no binding for the async
/// iterator of a directory handle.
Stream<String> _namesIn(web.FileSystemDirectoryHandle directory) async* {
  final iterator = (directory as JSObject).callMethod<JSObject>('keys'.toJS);
  while (true) {
    final next = await iterator
        .callMethod<JSPromise<JSObject>>('next'.toJS)
        .toDart;
    if (next.getProperty<JSBoolean?>('done'.toJS)?.toDart ?? false) return;
    yield next.getProperty<JSString>('value'.toJS).toDart;
  }
}

/// Whether [error] says the entry is not there.
bool _isMissing(Object error) => _nameOf(error) == 'NotFoundError';

/// The DOM exception's name, the error's code for diagnostics: never its
/// message.
String _errorCode(Object error) => switch (_nameOf(error)) {
  final name? => 'dom-$name',
  null => error.runtimeType.toString(),
};

String? _nameOf(Object error) => switch (error) {
  final JSObject box => switch (box.getProperty<JSAny?>('name'.toJS)) {
    final JSString name => name.toDart,
    _ => null,
  },
  _ => null,
};
