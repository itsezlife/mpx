import 'dart:convert';

import 'package:http_bytes_cache/http_bytes_cache.dart' show RequestPriority;
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_transfer/src/job/transfer_id.dart';
import 'package:mpx_transfer/src/job/transfer_job.dart';
import 'package:mpx_transfer/src/job/transfer_state.dart';
import 'package:mpx_transfer/src/journal/journal_record.dart';
import 'package:mpx_transfer/src/journal/json_fields.dart';
import 'package:mpx_transfer/src/upload/remote_ref.dart';
import 'package:mpx_transfer/src/upload/upload_lane.dart';

/// How one kind of [TransferResult] is written into the journal and read
/// back.
///
/// The engine never reads a result, so it cannot write one either: each
/// kind (an upload's remote reference, a download's cached file) brings its
/// codec, and the journal finds it by [kind]. Internal to the package.
abstract interface class TransferResultCodec {
  /// The kind's name in the journal; unique among the codecs.
  String get kind;

  /// [result] as JSON, or null when it is not of this kind.
  Map<String, Object?>? encode(TransferResult result);

  /// The result [json] holds, as [encode] wrote it.
  TransferResult decode(Map<String, Object?> json);
}

/// One entry of the journal: what a frame holds.
sealed class JournalEntry {
  const JournalEntry();
}

/// A job's record, replacing any earlier one of its id.
final class JournalEntry$Put extends JournalEntry {
  /// [record], put.
  const JournalEntry$Put(this.record);

  /// The record.
  final JournalRecord record;
}

/// A job was removed (cancelled or pruned).
final class JournalEntry$Remove extends JournalEntry {
  /// Job [id], removed.
  const JournalEntry$Remove(this.id);

  /// The job removed.
  final TransferId id;
}

/// The journal's entries as frame payloads, one entry a frame of the
/// journal's record log (which writes its own generation header frames).
///
/// ## Entries
///
/// | Entry | Frame payload |
/// |---|---|
/// | [JournalEntry$Put] | `{"put": record}` |
/// | [JournalEntry$Remove] | `{"remove": id}` |
///
/// A record is the job (`id`, `direction`, `durability`, `priority`,
/// `tag?`, `key?`, `resumeOnStart`, `createdAt`, `updatedAt`, `state`),
/// then `upload?`, `envelopeHandle?` and `lastProgressAt?`. A `state` is
/// tagged by `is` (`queued`, `running`, `paused`, `failed`, `completed`);
/// a completed one holds `result`, `{kind, value}`, the value written by
/// the [TransferResultCodec] of that kind. An `upload` holds its `source`
/// (`path`, `size`, `growing`, `fingerprint`, `modified?`), the transport
/// and its resume state, its acknowledged `parts`, its `owner?` and the
/// remote end's `finished?` answer (`{id, attributes?}`), kept until the
/// completed state is written.
///
/// ## Encoding
///
/// Enums by name; times in ISO 8601, which keeps whether a time was UTC,
/// so a record reads back equal to the one written. A field at its default
/// (null, false, 0, empty) is left out.
///
/// ## Decoding
///
/// A missing field reads as its default where the encoder leaves it out;
/// a missing required field, a wrong type, an unknown name or tag, or a
/// result kind no codec knows throws a [FormatException] naming the field,
/// and the log skips the frame and counts it. A part of an unknown shape
/// is dropped alone, since the upload sends it again.
///
/// ## Versioning
///
/// Records carry no version: a field is only ever added, read as its
/// default when an older record lacks it. A record an older build cannot
/// read (a new state tag, a new result kind) is skipped by that build.
final class JournalCodec extends Codec<JournalEntry, Object?> {
  /// A codec that writes and reads results through [resultCodecs].
  JournalCodec(Iterable<TransferResultCodec> resultCodecs)
    : this._({for (final codec in resultCodecs) codec.kind: codec});

  JournalCodec._(Map<String, TransferResultCodec> results)
    : encoder = _JournalEntryEncoder(results),
      decoder = _JournalEntryDecoder(results);

  @override
  final Converter<JournalEntry, Object?> encoder;

  @override
  final Converter<Object?, JournalEntry> decoder;
}

final class _JournalEntryEncoder extends Converter<JournalEntry, Object?> {
  const _JournalEntryEncoder(this._results);

  final Map<String, TransferResultCodec> _results;

  @override
  Object? convert(JournalEntry input) => switch (input) {
    JournalEntry$Put(:final record) => {_Key.put: _recordToJson(record)},
    JournalEntry$Remove(:final id) => {_Key.remove: id.value},
  };

  Map<String, Object?> _recordToJson(JournalRecord record) {
    final job = record.job;
    return {
      _Key.id: job.id.value,
      _Key.direction: job.direction.name,
      _Key.durability: job.durability.name,
      _Key.priority: job.priority.name,
      _Key.tag: ?job.tag,
      _Key.key: ?job.key?.encoded,
      _Key.resumeOnStart: job.resumeOnStart,
      _Key.createdAt: job.createdAt.toIso8601String(),
      _Key.updatedAt: job.updatedAt.toIso8601String(),
      _Key.state: _stateToJson(job.state),
      if (record.upload case final upload?) _Key.upload: _uploadToJson(upload),
      _Key.envelopeHandle: ?record.envelopeHandle,
      _Key.lastProgressAt: ?record.lastProgressAt?.toIso8601String(),
    };
  }

  /// A part is `[index]`, or `[index, receipt]` when the remote end gave
  /// one: the list stays short for a transport that gives none.
  Map<String, Object?> _uploadToJson(JournalUpload upload) => {
    _Key.source: {
      _Key.path: upload.source.path,
      _Key.size: upload.source.size,
      _Key.growing: upload.source.growing,
      _Key.fingerprint: upload.source.fingerprint,
      _Key.modified: ?upload.source.modified?.toIso8601String(),
    },
    _Key.transportId: upload.transportId,
    _Key.lane: upload.lane.name,
    _Key.partSize: upload.partSize,
    _Key.fileName: ?upload.fileName,
    _Key.contentType: ?upload.contentType,
    _Key.resumeToken: ?upload.resumeToken,
    _Key.resumeExpiresAt: ?upload.resumeExpiresAt?.toIso8601String(),
    if (upload.parts.isNotEmpty)
      _Key.parts: [
        for (final MapEntry(key: index, value: receipt) in upload.parts.entries)
          [index, ?receipt],
      ],
    if (upload.highWaterMark != 0) _Key.highWaterMark: upload.highWaterMark,
    if (upload.owner case final owner?)
      _Key.owner: {
        _Key.job: owner.job,
        _Key.item: owner.itemId,
        _Key.role: owner.role.name,
      },
    if (upload.finished case final finished?)
      _Key.finished: RemoteRef.codec.encode(finished),
  };

  Map<String, Object?> _stateToJson(TransferState state) => switch (state) {
    TransferState$Queued(:final total) => {
      _Key.variant: _Is.queued,
      _Key.total: ?total,
    },
    TransferState$Running(:final done, :final total, :final estimated) => {
      _Key.variant: _Is.running,
      _Key.done: done,
      _Key.total: ?total,
      if (estimated) _Key.estimated: true,
    },
    TransferState$Paused(:final reason, :final done, :final total) => {
      _Key.variant: _Is.paused,
      _Key.reason: reason.name,
      _Key.done: done,
      _Key.total: ?total,
    },
    TransferState$Failed(
      :final kind,
      :final retryable,
      :final done,
      :final total,
    ) =>
      {
        _Key.variant: _Is.failed,
        _Key.kind: kind.name,
        _Key.retryable: retryable,
        _Key.done: done,
        _Key.total: ?total,
      },
    TransferState$Completed(:final result) => {
      _Key.variant: _Is.completed,
      _Key.result: _resultToJson(result),
    },
  };

  Map<String, Object?> _resultToJson(TransferResult result) {
    for (final codec in _results.values) {
      if (codec.encode(result) case final json?) {
        return {_Key.kind: codec.kind, _Key.value: json};
      }
    }
    throw ArgumentError.value(
      result,
      'result',
      'has no TransferResultCodec: each result kind brings one',
    );
  }
}

final class _JournalEntryDecoder extends Converter<Object?, JournalEntry> {
  const _JournalEntryDecoder(this._results);

  final Map<String, TransferResultCodec> _results;

  @override
  JournalEntry convert(Object? input) => switch (input) {
    {_Key.put: final Map<String, Object?> record} => JournalEntry$Put(
      _recordFromJson(JsonFields(record)),
    ),
    {_Key.remove: final String id} => JournalEntry$Remove(TransferId.parse(id)),
    _ => throw FormatException('Expected a journal entry.', input),
  };

  JournalRecord _recordFromJson(JsonFields json) => JournalRecord(
    job: TransferJob(
      id: TransferId.parse(json.string(_Key.id)),
      direction: json.byName(TransferDirection.values, _Key.direction),
      durability: json.byName(TransferDurability.values, _Key.durability),
      priority: json.byName(RequestPriority.values, _Key.priority),
      tag: json.optionalString(_Key.tag),
      key: switch (json.optionalString(_Key.key)) {
        final encoded? =>
          MediaKey.tryParse(encoded) ??
              (throw FormatException(
                'Expected a media key under "${_Key.key}".',
                json.json,
              )),
        null => null,
      },
      resumeOnStart: json.flag(_Key.resumeOnStart),
      createdAt: json.time(_Key.createdAt),
      updatedAt: json.time(_Key.updatedAt),
      state: _stateFromJson(json.object(_Key.state)),
    ),
    upload: switch (json.optionalObject(_Key.upload)) {
      final upload? => _uploadFromJson(upload),
      null => null,
    },
    envelopeHandle: json.optionalString(_Key.envelopeHandle),
    lastProgressAt: json.optionalTime(_Key.lastProgressAt),
  );

  JournalUpload _uploadFromJson(JsonFields json) {
    final source = json.object(_Key.source);
    return JournalUpload(
      source: JournalSource(
        path: source.string(_Key.path),
        size: source.integer(_Key.size),
        growing: source.flag(_Key.growing),
        fingerprint: source.string(_Key.fingerprint),
        modified: source.optionalTime(_Key.modified),
      ),
      transportId: json.string(_Key.transportId),
      lane: json.byName(UploadLane.values, _Key.lane),
      partSize: json.integer(_Key.partSize),
      fileName: json.optionalString(_Key.fileName),
      contentType: json.optionalString(_Key.contentType),
      resumeToken: json.optionalString(_Key.resumeToken),
      resumeExpiresAt: json.optionalTime(_Key.resumeExpiresAt),
      parts: {
        // A part of another shape is dropped, not the record: the part is
        // sent again.
        for (final part in json.optionalList(_Key.parts))
          if (part case [final int index])
            index: null
          else if (part case [final int index, final String receipt])
            index: receipt,
      },
      highWaterMark: json.optionalInteger(_Key.highWaterMark) ?? 0,
      owner: switch (json.optionalObject(_Key.owner)) {
        final owner? => JournalUploadOwner(
          job: owner.string(_Key.job),
          itemId: owner.string(_Key.item),
          role: owner.byName(UploadRole.values, _Key.role),
        ),
        null => null,
      },
      finished: switch (json.optionalObject(_Key.finished)) {
        final finished? => RemoteRef.codec.decode(finished.json) as RemoteRef,
        null => null,
      },
    );
  }

  TransferState _stateFromJson(JsonFields json) {
    final total = json.optionalInteger(_Key.total);
    final done = json.optionalInteger(_Key.done) ?? 0;
    return switch (json.string(_Key.variant)) {
      _Is.queued => TransferState.queued(total: total),
      _Is.running => TransferState.running(
        done: done,
        total: total,
        estimated: json.optionalFlag(_Key.estimated),
      ),
      _Is.paused => TransferState.paused(
        reason: json.byName(PauseReason.values, _Key.reason),
        done: done,
        total: total,
      ),
      _Is.failed => TransferState.failed(
        kind: json.byName(TransferFailureKind.values, _Key.kind),
        retryable: json.flag(_Key.retryable),
        done: done,
        total: total,
      ),
      _Is.completed => TransferState.completed(
        _resultFromJson(json.object(_Key.result)),
      ),
      final other => throw FormatException(
        'Unknown transfer state "$other" under "${_Key.variant}".',
        json.json,
      ),
    };
  }

  TransferResult _resultFromJson(JsonFields json) {
    final kind = json.string(_Key.kind);
    final codec =
        _results[kind] ??
        (throw FormatException(
          'No codec for the result kind "$kind" under "${_Key.kind}".',
          json.json,
        ));
    return codec.decode(json.object(_Key.value).json);
  }
}

/// Field names shared by both directions.
abstract final class _Key {
  // An entry.
  static const String put = 'put';
  static const String remove = 'remove';

  // A record.
  static const String id = 'id';
  static const String direction = 'direction';
  static const String durability = 'durability';
  static const String priority = 'priority';
  static const String tag = 'tag';
  static const String key = 'key';
  static const String resumeOnStart = 'resumeOnStart';
  static const String createdAt = 'createdAt';
  static const String updatedAt = 'updatedAt';
  static const String state = 'state';
  static const String upload = 'upload';
  static const String envelopeHandle = 'envelopeHandle';
  static const String lastProgressAt = 'lastProgressAt';

  // An upload.
  static const String source = 'source';
  static const String path = 'path';
  static const String size = 'size';
  static const String growing = 'growing';
  static const String fingerprint = 'fingerprint';
  static const String modified = 'modified';
  static const String transportId = 'transportId';
  static const String lane = 'lane';
  static const String partSize = 'partSize';
  static const String fileName = 'fileName';
  static const String contentType = 'contentType';
  static const String resumeToken = 'resumeToken';
  static const String resumeExpiresAt = 'resumeExpiresAt';
  static const String parts = 'parts';
  static const String highWaterMark = 'highWaterMark';
  static const String owner = 'owner';
  static const String job = 'job';
  static const String item = 'item';
  static const String role = 'role';
  static const String finished = 'finished';

  // A state.
  static const String variant = 'is';
  static const String total = 'total';
  static const String done = 'done';
  static const String estimated = 'estimated';
  static const String reason = 'reason';
  static const String kind = 'kind';
  static const String retryable = 'retryable';
  static const String result = 'result';
  static const String value = 'value';
}

/// The `is` tags of a state.
abstract final class _Is {
  static const String queued = 'queued';
  static const String running = 'running';
  static const String paused = 'paused';
  static const String failed = 'failed';
  static const String completed = 'completed';
}
