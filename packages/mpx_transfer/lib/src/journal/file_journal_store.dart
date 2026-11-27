import 'dart:io';
import 'dart:typed_data';

import 'package:mpx_transfer/src/journal/journal_store.dart';

/// A [JournalStore] in two files of [directory]: `journal.snapshot` and
/// `journal.log`.
///
/// The log is held open in append mode, and every append is flushed before
/// its future completes. The snapshot is written to a temporary file and
/// renamed over the old one, so it is replaced whole or not at all.
final class FileJournalStore implements JournalStore {
  /// A store in [directory], which is made when the store first writes.
  ///
  /// [directory] belongs to the journal alone: the bytes cache deletes the
  /// files it does not know at the top of its own directory, so the
  /// journal sits in a directory of its own below it.
  FileJournalStore(this.directory);

  /// Where the two files are.
  final String directory;

  RandomAccessFile? _log;

  @override
  JournalStoreKind get kind => JournalStoreKind.file;

  String _pathOf(JournalBlob blob) =>
      '$directory${Platform.pathSeparator}journal.${blob.name}';

  @override
  Future<Uint8List> read(JournalBlob blob) async {
    final file = File(_pathOf(blob));
    if (!file.existsSync()) return Uint8List(0);
    return file.readAsBytes();
  }

  @override
  Future<void> append(Uint8List bytes) async {
    final log = _log ??= await _openLog(FileMode.append);
    await log.writeFrom(bytes);
    await log.flush();
  }

  @override
  Future<void> replace({
    required Uint8List snapshot,
    required Uint8List log,
  }) async {
    await Directory(directory).create(recursive: true);
    final path = _pathOf(JournalBlob.snapshot);
    final temporary = await File('$path.tmp').open(mode: FileMode.write);
    try {
      await temporary.writeFrom(snapshot);
      await temporary.flush();
    } finally {
      await temporary.close();
    }
    await File('$path.tmp').rename(path);

    await _log?.close();
    _log = null;
    final fresh = await _openLog(FileMode.write);
    _log = fresh;
    await fresh.writeFrom(log);
    await fresh.flush();
  }

  Future<RandomAccessFile> _openLog(FileMode mode) async {
    await Directory(directory).create(recursive: true);
    return File(_pathOf(JournalBlob.log)).open(mode: mode);
  }

  @override
  Future<void> close() async {
    final log = _log;
    _log = null;
    await log?.close();
  }

  @override
  String errorCode(Object error) => switch (error) {
    FileSystemException(:final osError?) => 'os-${osError.errorCode}',
    FileSystemException() => 'io',
    _ => error.runtimeType.toString(),
  };
}
