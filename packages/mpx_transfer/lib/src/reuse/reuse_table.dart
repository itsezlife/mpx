import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_transfer/src/diagnostics/journal_op.dart';
import 'package:mpx_transfer/src/diagnostics/reuse_op.dart';
import 'package:mpx_transfer/src/diagnostics/transfers_debug_snapshot.dart';
import 'package:mpx_transfer/src/journal/journal_frames.dart';
import 'package:mpx_transfer/src/journal/journal_store.dart';
import 'package:mpx_transfer/src/journal/json_fields.dart';
import 'package:mpx_transfer/src/upload/remote_ref.dart';
import 'package:mpx_transfer/src/upload/upload_transport.dart';

/// What the reuse table knows one source by: its fingerprint and the
/// preparation it is sent with.
///
/// The same file sent as a photo and as a file is two sources, since the
/// bytes that reach the remote end differ. Two keys are equal when both
/// parts are; the key is held in one canonical form, made once here.
@immutable
final class ReuseKey {
  /// A source the host fingerprinted: [fingerprint] is the item's own
  /// value (for an item of the device's library, built from its asset id
  /// and modification date). [preparation] is how it is prepared; null for
  /// a file that goes as it is.
  ReuseKey.host(String fingerprint, {PreparationIntent? preparation})
    : this._of('host:$fingerprint', preparation);

  /// A file the host did not fingerprint, known by its [path], [size] and
  /// [modified] time: any change to the file makes another key.
  /// [preparation] is how it is prepared; null for a file that goes as it
  /// is.
  ReuseKey.file({
    required String path,
    required int size,
    required DateTime modified,
    PreparationIntent? preparation,
  }) : this._of(
         'file:${modified.toUtc().microsecondsSinceEpoch}:$size:$path',
         preparation,
       );

  ReuseKey._of(String fingerprint, PreparationIntent? preparation)
    : _value = jsonEncode([
        fingerprint,
        if (preparation != null) PreparationEncoding.encodeIntent(preparation),
      ]);

  const ReuseKey._(this._value);

  /// The key [encoded] holds, as a publish job's record keeps it.
  @internal
  const ReuseKey.decode(String encoded) : this._(encoded);

  /// The canonical form, for a publish job's record.
  @internal
  String get encoded => _value;

  /// The canonical form, as the table stores it.
  final String _value;

  @override
  bool operator ==(Object other) => other is ReuseKey && other._value == _value;

  @override
  int get hashCode => _value.hashCode;

  // The fingerprint may hold a path: it stays out of logs.
  @override
  String toString() => 'ReuseKey(${_value.length})';
}

/// What the reuse table holds for one source: where its upload lives on
/// the remote end, and since when.
@immutable
final class ReuseEntry {
  /// An entry of [file] (and [thumbnail]), stored at [storedAt] and
  /// dropped at [expiresAt].
  const ReuseEntry({
    required this.file,
    required this.storedAt,
    required this.expiresAt,
    this.thumbnail,
  });

  /// The uploaded file's reference.
  final RemoteRef file;

  /// The uploaded thumbnail's reference, when the transport uploads one
  /// separately.
  final RemoteRef? thumbnail;

  /// When the references were stored.
  final DateTime storedAt;

  /// When the host's expiry drops the entry, whatever the transport says.
  final DateTime expiresAt;

  @override
  bool operator ==(Object other) =>
      other is ReuseEntry &&
      other.file == file &&
      other.thumbnail == thumbnail &&
      other.storedAt == storedAt &&
      other.expiresAt == expiresAt;

  @override
  int get hashCode => Object.hash(file, thumbnail, storedAt, expiresAt);

  @override
  String toString() => 'ReuseEntry(stored $storedAt)';
}

/// The host's say over the reuse table: whether it is on, and how long an
/// entry is kept.
@immutable
final class ReusePolicy {
  /// The table on, keeping an entry for [expiry] after it was stored.
  const ReusePolicy({this.expiry = defaultExpiry}) : enabled = true;

  /// The table off: every source is prepared and uploaded, and nothing is
  /// stored.
  const ReusePolicy.off() : enabled = false, expiry = Duration.zero;

  /// How long an entry is kept by default: 7 days. The transport judges
  /// within it whether a stored reference is still good; the expiry bounds
  /// how long the table holds on to sources nobody sends again.
  static const Duration defaultExpiry = Duration(days: 7);

  /// Whether sources are looked up and stored.
  final bool enabled;

  /// How long after it was stored an entry is dropped.
  final Duration expiry;

  @override
  bool operator ==(Object other) =>
      other is ReusePolicy &&
      other.enabled == enabled &&
      other.expiry == expiry;

  @override
  int get hashCode => Object.hash(enabled, expiry);
}

/// Sending the same media again without preparing or uploading it again:
/// a table from a source ([ReuseKey]) and the transport that carried it to
/// the references its upload answered ([ReuseEntry]).
///
/// A publish job looks an item up before it prepares it ([lookup]); a
/// valid hit is the item uploaded at once. Whether a stored reference is
/// still good is the transport's call, through its `reuse` capability: a
/// lifetime since it was stored, or a call to the remote end. After an
/// upload the job [store]s the references; a publisher that asks for an
/// item again has its entry dropped ([invalidate]). The host's
/// [ReusePolicy] turns the table off or sets how long an entry is kept.
///
/// Kept beside the journal, in the same kind of storage, so it survives a
/// restart and any kill: a change is appended and flushed at once, and the
/// table is folded into a fresh snapshot at each start and every
/// [compactAfter] changes. A write that fails leaves memory as it is and
/// makes the next write rewrite the whole table.
///
/// Single-threaded on the UI isolate.
final class ReuseTable {
  ReuseTable._({
    required JournalStore store,
    required this.policy,
    required Map<_Slot, ReuseEntry> entries,
    required this.compactAfter,
    required DateTime Function() now,
  }) : _store = store,
       _entries = entries,
       _now = now;

  /// Reads [store] back, drops the entries past [policy]'s expiry and
  /// folds the rest into a fresh snapshot.
  ///
  /// With the table off, [store] is not read: what it holds is left for a
  /// run with the table on. A store that cannot be read is reported
  /// (`journal` `writeFailed`, `table: reuse`) and replaced by memory for
  /// this run, so the table starts empty.
  @internal
  static Future<ReuseTable> open(
    JournalStore store, {
    ReusePolicy policy = const ReusePolicy(),
    DateTime Function() now = DateTime.now,
    int compactAfter = defaultCompactAfter,
  }) async {
    if (!policy.enabled) {
      return ReuseTable._(
        store: store,
        policy: policy,
        entries: {},
        compactAfter: compactAfter,
        now: now,
      );
    }
    var source = store;
    final entries = <_Slot, _Stored>{};
    try {
      final snapshot = await source.read(JournalBlob.snapshot);
      final log = await source.read(JournalBlob.log);
      // A kill between the two steps of a compaction leaves the new
      // snapshot beside the old log. The log holds only changes the
      // snapshot already folded, so replaying it after the snapshot ends
      // in the same table; an expired entry it brings back is dropped
      // below with the rest.
      for (final payload in [
        ...JournalFrames.decode(snapshot).payloads,
        ...JournalFrames.decode(log).payloads,
      ]) {
        _apply(entries, payload);
      }
    } on Object catch (error, stackTrace) {
      _emitWriteFailed(source, error, stackTrace);
      source = MemoryJournalStore();
      entries.clear();
    }

    final table = ReuseTable._(
      store: source,
      policy: policy,
      entries: {
        for (final MapEntry(:key, :value) in entries.entries)
          key: value.entry(policy.expiry),
      },
      compactAfter: compactAfter,
      now: now,
    );
    final time = now();
    // Dropped in memory only: the compaction right after writes the rest.
    table._entries.removeWhere((_, entry) {
      final expired = !time.isBefore(entry.expiresAt);
      if (expired) _emitInvalidated('expired');
      return expired;
    });
    await table._compact();
    return table;
  }

  /// How many changes the log takes by default before it is folded into
  /// the snapshot during a run.
  static const int defaultCompactAfter = 200;

  /// The host's say over the table.
  final ReusePolicy policy;

  /// How many changes the log takes before it is folded during a run.
  final int compactAfter;

  final JournalStore _store;
  final Map<_Slot, ReuseEntry> _entries;
  final DateTime Function() _now;

  int _hits = 0;
  int _misses = 0;
  int _changesSinceCompaction = 0;
  bool _rewrite = false;
  bool _closed = false;
  bool _abandoned = false;
  Future<void> _tail = Future.value();

  // --- Lookups ---------------------------------------------------------------

  /// The references stored for [key] sent through [transport], when the
  /// transport judges them still good; null otherwise, and the source is
  /// prepared and uploaded.
  ///
  /// An entry past the host's expiry, or one the transport judges no
  /// longer good, is dropped. A validity call that throws is a miss that
  /// keeps the entry: the remote end did not say the file is gone. [jobId],
  /// [itemId] and [mediaKey] correlate the events.
  Future<ReuseEntry?> lookup(
    ReuseKey key,
    UploadTransport transport, {
    String? jobId,
    String? itemId,
    MediaKey? mediaKey,
  }) async {
    void emit(MpxEventLevel level, ReuseOp op, Map<String, Object> fields) =>
        MpxDiagnostics.current.emit(
          level,
          op,
          jobId: jobId,
          itemId: itemId,
          mediaKey: mediaKey,
          fields: () => fields,
        );
    ReuseEntry? answer(ReuseEntry? hit) {
      if (hit == null) _misses++;
      emit(MpxEventLevel.trace, ReuseOp.lookup, {
        'result': hit == null ? 'miss' : 'hit',
      });
      return hit;
    }

    if (!policy.enabled) {
      emit(MpxEventLevel.trace, ReuseOp.lookup, {'result': 'disabled'});
      return null;
    }
    final slot = (transport: transport.id, key: key);
    final entry = _entries[slot];
    if (entry == null) return answer(null);
    if (!_now().isBefore(entry.expiresAt)) {
      _drop(slot, 'expired', jobId: jobId, itemId: itemId, mediaKey: mediaKey);
      return answer(null);
    }

    final String judgedBy;
    switch (transport.capabilities.reuse) {
      case UploadReuse$Lifetime(:final lifetime):
        judgedBy = 'lifetime';
        if (!_now().isBefore(entry.storedAt.add(lifetime))) {
          emit(MpxEventLevel.info, ReuseOp.judgedInvalid, {
            'judgedBy': judgedBy,
          });
          _remove(slot);
          return answer(null);
        }
      case UploadReuse$Validity(:final isValid):
        judgedBy = 'validityCall';
        final bool valid;
        try {
          valid =
              await isValid(entry.file) &&
              (entry.thumbnail == null || await isValid(entry.thumbnail!));
        } on Object catch (error, stackTrace) {
          MpxDiagnostics.current.emit(
            MpxEventLevel.info,
            ReuseOp.judgedInvalid,
            jobId: jobId,
            itemId: itemId,
            mediaKey: mediaKey,
            fields: () => {'judgedBy': judgedBy, 'callFailed': true},
            stackTrace: stackTrace,
          );
          return answer(null);
        }
        if (!valid) {
          emit(MpxEventLevel.info, ReuseOp.judgedInvalid, {
            'judgedBy': judgedBy,
          });
          // Only the entry judged: a newer one stored meanwhile stays.
          if (_entries[slot] == entry) _remove(slot);
          return answer(null);
        }
    }
    _hits++;
    emit(MpxEventLevel.debug, ReuseOp.hit, {
      'ageS': _now().difference(entry.storedAt).inSeconds,
      'judgedBy': judgedBy,
    });
    return answer(entry);
  }

  // --- Changes ---------------------------------------------------------------

  /// Keeps the references the upload of [key] through [transport] answered,
  /// replacing any stored before, and writes them at once. Nothing is kept
  /// with the table off.
  void store(
    ReuseKey key,
    UploadTransport transport, {
    required RemoteRef file,
    RemoteRef? thumbnail,
    String? jobId,
    String? itemId,
    MediaKey? mediaKey,
  }) {
    if (_closed || !policy.enabled) return;
    final slot = (transport: transport.id, key: key);
    final storedAt = _now();
    final entry = ReuseEntry(
      file: file,
      thumbnail: thumbnail,
      storedAt: storedAt,
      expiresAt: storedAt.add(policy.expiry),
    );
    _entries[slot] = entry;
    _write(_putJson(slot, entry));
    MpxDiagnostics.current.emit(
      MpxEventLevel.debug,
      ReuseOp.stored,
      jobId: jobId,
      itemId: itemId,
      mediaKey: mediaKey,
      fields: () => {'expiresInH': policy.expiry.inHours},
    );
  }

  /// Drops the entry of [key] sent through [transport], because its
  /// publisher asked for the source again; answers whether there was one.
  bool invalidate(
    ReuseKey key,
    UploadTransport transport, {
    String? jobId,
    String? itemId,
    MediaKey? mediaKey,
  }) {
    final slot = (transport: transport.id, key: key);
    if (_closed || !_entries.containsKey(slot)) return false;
    _drop(
      slot,
      'reuploadItems',
      jobId: jobId,
      itemId: itemId,
      mediaKey: mediaKey,
    );
    return true;
  }

  // --- Lifecycle -------------------------------------------------------------

  /// The table now, for a debug panel.
  ReuseDebugSnapshot debugSnapshot() => ReuseDebugSnapshot(
    enabled: policy.enabled,
    entries: _entries.length,
    hits: _hits,
    misses: _misses,
  );

  /// Completes when every write made so far has finished.
  @internal
  Future<void> get idle => _tail;

  /// Waits for every write and releases the store. Changes after this are
  /// ignored.
  Future<void> close() async {
    if (_closed) return _tail;
    _closed = true;
    await _tail;
    await _store.close();
  }

  /// Stops as a killed process would: writes not yet begun are never made.
  @internal
  void abandon() {
    if (_closed) return;
    _closed = true;
    _abandoned = true;
    unawaited(_tail.then((_) => _store.close()));
  }

  // --- Internals -------------------------------------------------------------

  void _drop(
    _Slot slot,
    String why, {
    String? jobId,
    String? itemId,
    MediaKey? mediaKey,
  }) {
    _remove(slot);
    _emitInvalidated(why, jobId: jobId, itemId: itemId, mediaKey: mediaKey);
  }

  static void _emitInvalidated(
    String why, {
    String? jobId,
    String? itemId,
    MediaKey? mediaKey,
  }) => MpxDiagnostics.current.emit(
    MpxEventLevel.info,
    ReuseOp.invalidated,
    jobId: jobId,
    itemId: itemId,
    mediaKey: mediaKey,
    fields: () => {'why': why},
  );

  void _remove(_Slot slot) {
    if (_entries.remove(slot) == null || _closed) return;
    _write({_Key.remove: _slotJson(slot)});
  }

  /// Appends [change] after the writes before it; encoded here, so a change
  /// that cannot be encoded throws where it was made.
  void _write(Map<String, Object?> change) {
    final bytes = JournalFrames.encode([change]);
    _tail = _tail.then((_) async {
      if (_abandoned) return;
      if (_rewrite) {
        // Memory already holds the change; the rewrite writes it.
        await _compact();
        return;
      }
      try {
        await _store.append(bytes);
      } on Object catch (error, stackTrace) {
        _rewrite = true;
        _emitWriteFailed(_store, error, stackTrace);
        return;
      }
      if (++_changesSinceCompaction >= compactAfter) await _compact();
    });
  }

  Future<void> _compact() async {
    final snapshot = JournalFrames.encode([
      for (final MapEntry(:key, :value) in _entries.entries)
        _putJson(key, value),
    ]);
    try {
      await _store.replace(snapshot: snapshot, log: Uint8List(0));
    } on Object catch (error, stackTrace) {
      _rewrite = true;
      _emitWriteFailed(_store, error, stackTrace);
      return;
    }
    _changesSinceCompaction = 0;
    _rewrite = false;
  }

  // --- Stored form ----------------------------------------------------------
  //
  // A change is a frame of `{"put": {transport, key, file, thumbnail?,
  // storedAt}}` or `{"remove": {transport, key}}`: `key` is the reuse key's
  // canonical form, `file` and `thumbnail` remote references as the journal
  // writes them, `storedAt` ISO 8601. The expiry is not stored; the run that
  // reads an entry applies its own.

  static Map<String, Object?> _slotJson(_Slot slot) => {
    _Key.transport: slot.transport,
    _Key.key: slot.key._value,
  };

  static Map<String, Object?> _putJson(_Slot slot, ReuseEntry entry) => {
    _Key.put: {
      ..._slotJson(slot),
      _Key.file: RemoteRef.codec.encode(entry.file),
      if (entry.thumbnail case final thumbnail?)
        _Key.thumbnail: RemoteRef.codec.encode(thumbnail),
      _Key.storedAt: entry.storedAt.toIso8601String(),
    },
  };

  /// Applies one change read back to [entries]; a change this build cannot
  /// read (a newer version's, one cut short) throws a [FormatException]
  /// naming the field and is skipped.
  static void _apply(Map<_Slot, _Stored> entries, Object? payload) {
    try {
      switch (payload) {
        case {_Key.put: final Map<String, Object?> json}:
          final put = JsonFields(json);
          entries[_slotOf(put)] = (
            file: _refOf(put.object(_Key.file)),
            thumbnail: switch (put.optionalObject(_Key.thumbnail)) {
              final thumbnail? => _refOf(thumbnail),
              null => null,
            },
            storedAt: put.time(_Key.storedAt),
          );
        case {_Key.remove: final Map<String, Object?> remove}:
          entries.remove(_slotOf(JsonFields(remove)));
      }
    } on Object {
      // A change of a newer version: skipped, as the journal skips one.
    }
  }

  static _Slot _slotOf(JsonFields json) => (
    transport: json.string(_Key.transport),
    key: ReuseKey._(json.string(_Key.key)),
  );

  static RemoteRef _refOf(JsonFields json) =>
      RemoteRef.codec.decode(json.json) as RemoteRef;

  static void _emitWriteFailed(
    JournalStore store,
    Object error,
    StackTrace stackTrace,
  ) => MpxDiagnostics.current.emit(
    MpxEventLevel.error,
    JournalOp.writeFailed,
    // The error itself stays out: a file system error names its path.
    fields: () => {'code': store.errorCode(error), 'table': 'reuse'},
    stackTrace: stackTrace,
  );
}

/// Field names of the table's stored form.
abstract final class _Key {
  static const String put = 'put';
  static const String remove = 'remove';
  static const String transport = 'transport';
  static const String key = 'key';
  static const String file = 'file';
  static const String thumbnail = 'thumbnail';
  static const String storedAt = 'storedAt';
}

/// Where an entry sits: the transport that carried the source, and the
/// source. A reference means nothing to another transport.
typedef _Slot = ({String transport, ReuseKey key});

/// An entry as stored: its expiry follows the host's policy of the run
/// that reads it, so a shorter expiry applies to what was stored before.
typedef _Stored = ({RemoteRef file, RemoteRef? thumbnail, DateTime storedAt});

extension on _Stored {
  ReuseEntry entry(Duration expiry) => ReuseEntry(
    file: file,
    thumbnail: thumbnail,
    storedAt: storedAt,
    expiresAt: storedAt.add(expiry),
  );
}
