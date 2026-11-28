import 'dart:typed_data';

/// Where the journal's bytes live: two blobs, a snapshot and a log, and
/// nothing about what the bytes mean.
///
/// The journal above it frames, checks and folds the records, so every
/// platform's store (a file on the VM, OPFS on the web, memory where
/// neither is there) only reads, appends and replaces bytes. The journal
/// calls one method at a time and waits for it, so a store needs no
/// locking of its own.
///
/// Internal to the package: hosts never see a store.
abstract interface class JournalStore {
  /// What kind of storage this is, for diagnostics.
  JournalStoreKind get kind;

  /// Everything in [blob]; empty when it was never written.
  Future<Uint8List> read(JournalBlob blob);

  /// Adds [bytes] at the end of the log. Durable when the future completes:
  /// a kill after that keeps them; a kill before it may keep a part.
  Future<void> append(Uint8List bytes);

  /// Replaces the snapshot with [snapshot], then the log with [log].
  ///
  /// The snapshot is replaced whole or not at all; a kill between the two
  /// steps leaves the new snapshot beside the old log, which the journal
  /// tells apart by the generation each one starts with.
  Future<void> replace({required Uint8List snapshot, required Uint8List log});

  /// Releases what the store holds open. What was written stays.
  Future<void> close();

  /// A short code for [error], thrown by one of this store's calls, for
  /// diagnostics: never a path or a message, which can carry user content.
  String errorCode(Object error);
}

/// The two blobs of a [JournalStore].
enum JournalBlob {
  /// Every live record as of the last compaction.
  snapshot,

  /// The records written since, oldest first.
  log,
}

/// The storage behind a journal, as diagnostics name it.
enum JournalStoreKind {
  /// A file on the device (the VM).
  file,

  /// The origin private file system (the web).
  opfs,

  /// Memory only: nothing survives the process.
  memory,
}

/// A [JournalStore] in memory: it lives as long as the object, so a new
/// journal over the same store reads what the last one wrote, as after a
/// restart.
///
/// The store of a platform with no durable storage, and the one engine
/// tests run over.
final class MemoryJournalStore implements JournalStore {
  final BytesBuilder _snapshot = BytesBuilder();
  final BytesBuilder _log = BytesBuilder();

  @override
  JournalStoreKind get kind => JournalStoreKind.memory;

  /// The bytes of [blob] now, without waiting.
  Uint8List bytesOf(JournalBlob blob) => switch (blob) {
    JournalBlob.snapshot => _snapshot.toBytes(),
    JournalBlob.log => _log.toBytes(),
  };

  @override
  Future<Uint8List> read(JournalBlob blob) async => bytesOf(blob);

  @override
  Future<void> append(Uint8List bytes) async => _log.add(bytes);

  @override
  Future<void> replace({
    required Uint8List snapshot,
    required Uint8List log,
  }) async {
    _snapshot
      ..clear()
      ..add(snapshot);
    _log
      ..clear()
      ..add(log);
  }

  @override
  Future<void> close() async {}

  @override
  String errorCode(Object error) => error.runtimeType.toString();
}
