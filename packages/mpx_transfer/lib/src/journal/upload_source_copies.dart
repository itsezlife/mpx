import 'dart:typed_data';

import 'package:mpx_transfer/src/job/transfer_id.dart';
import 'package:mpx_transfer/src/journal/source_bytes_blob.dart';

/// The bytes of one upload source as the page holds them: a file the user
/// picked, or bytes in memory. A host gives one where an upload has no
/// file to read (`PublishItem.pageSource`), or a new source for a failed
/// upload (`Transfers.retry`, `PublishJob.retryItem`), and makes it with
/// [SourceBytes.blob], [SourceBytes.memory] or [SourceBytes.file]: the
/// engine reads no other kind.
///
/// On the web a source has no path that outlives the page, so the engine
/// copies it ([UploadSourceCopies]) when its upload is made and reads the
/// copy after a reload. On the VM an upload reads a file, so the engine
/// writes in-memory bytes to a file of its own first.
abstract interface class SourceBytes {
  /// The [bytes] in memory.
  factory SourceBytes.memory(Uint8List bytes) = MemorySourceBytes;

  /// A browser `Blob` (a picked `File`), held as long as the page is. The
  /// web only: typed [Object] so the VM compiles without the browser's
  /// types. Throws an [ArgumentError] for anything but a `Blob`, and an
  /// [UnsupportedError] on the VM.
  factory SourceBytes.blob(Object blob) => $blobSourceBytes(blob);

  /// The file at [path], [size] bytes long, uploaded as it is, with no
  /// copy. The VM only: throws an [UnsupportedError] on the web.
  factory SourceBytes.file(String path, {required int size}) =>
      $fileSourceBytes(path, size);

  /// How many bytes the source holds.
  int get size;

  /// The bytes from [start] up to [end] (the end of the source when null).
  Future<Uint8List> read([int start = 0, int? end]);
}

/// [SourceBytes] of a file, on the VM: an upload reads it at [path].
abstract interface class SourceBytes$File implements SourceBytes {
  /// Where the file is.
  String get path;
}

/// [SourceBytes] held in memory.
final class MemorySourceBytes implements SourceBytes {
  /// A source of [bytes].
  MemorySourceBytes(this.bytes);

  /// The source's bytes.
  final Uint8List bytes;

  @override
  int get size => bytes.length;

  @override
  Future<Uint8List> read([int start = 0, int? end]) async =>
      Uint8List.sublistView(bytes, start, end);
}

/// Where the web keeps a copy of each upload source, so a job outlives a
/// reload of the page.
///
/// A job's sources are kept together: [copy] keeps all of them or none,
/// and [holds] answers for the whole job. A copy cut short (a reload in
/// the middle of it) reads as not kept at the next start, and its bytes
/// are deleted then. What is kept is known from the start on, so [holds]
/// answers at once.
///
/// Internal to the package: hosts never see it. The VM has none, because
/// a source there is a file that survives by itself.
abstract interface class UploadSourceCopies {
  /// Whether job [id]'s sources are all kept.
  bool holds(TransferId id);

  /// Every job whose sources are kept.
  Iterable<TransferId> get held;

  /// Copies [sources], in order, as job [id]'s; answers whether they are
  /// kept, which is false for a store that keeps nothing. Throws when the
  /// storage refuses the copy; nothing of it is kept then.
  Future<bool> copy(TransferId id, List<SourceBytes> sources);

  /// The copy of job [id]'s source at [index], or null when none is kept.
  Future<SourceBytes?> read(TransferId id, int index);

  /// Deletes job [id]'s copies. Deleting what is not kept does nothing.
  Future<void> delete(TransferId id);

  /// A short code for [error], thrown by one of these calls, for
  /// diagnostics: never a path or a message.
  String errorCode(Object error);
}

/// The [UploadSourceCopies] of a page with nowhere to keep them (no OPFS):
/// it keeps nothing, so every upload job comes back from a reload with its
/// source lost.
final class NoUploadSourceCopies implements UploadSourceCopies {
  /// The store that keeps nothing.
  const NoUploadSourceCopies();

  @override
  bool holds(TransferId id) => false;

  @override
  Iterable<TransferId> get held => const [];

  @override
  Future<bool> copy(TransferId id, List<SourceBytes> sources) async => false;

  @override
  Future<SourceBytes?> read(TransferId id, int index) async => null;

  @override
  Future<void> delete(TransferId id) async {}

  @override
  String errorCode(Object error) => error.runtimeType.toString();
}
