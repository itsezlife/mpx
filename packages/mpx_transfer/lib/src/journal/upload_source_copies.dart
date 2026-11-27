import 'dart:typed_data';

import 'package:mpx_transfer/src/job/transfer_id.dart';

/// The bytes of one upload source as the page holds them: a file the user
/// picked, or bytes in memory.
///
/// On the web a source has no path that outlives the page, so the engine
/// copies it ([UploadSourceCopies]) at job creation; on the VM a source is
/// a file at its path and is never copied.
abstract interface class SourceBytes {
  /// How many bytes the source holds.
  int get size;

  /// The bytes from [start] up to [end] (the end of the source when null).
  Future<Uint8List> read([int start = 0, int? end]);
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
