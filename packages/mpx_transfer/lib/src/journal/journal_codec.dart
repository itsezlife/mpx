import 'dart:typed_data';

import 'package:http_bytes_cache/http_bytes_cache.dart' show RequestPriority;
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_transfer/src/job/transfer_id.dart';
import 'package:mpx_transfer/src/job/transfer_job.dart';
import 'package:mpx_transfer/src/job/transfer_state.dart';
import 'package:mpx_transfer/src/journal/journal_frames.dart';
import 'package:mpx_transfer/src/journal/journal_record.dart';
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

/// The first entry of the snapshot and of the log: which compaction wrote
/// them. A log whose generation is not the snapshot's predates it.
final class JournalEntry$Header extends JournalEntry {
  /// The header of [generation].
  const JournalEntry$Header(this.generation);

  /// The compaction count.
  final int generation;
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

/// What [JournalCodec.decode] read from a blob.
typedef JournalRead = ({
  /// The entries read, in order.
  List<JournalEntry> entries,

  /// Frames whose bytes were whole but whose content could not be read
  /// back (a newer version's record, a result kind no codec knows).
  int skipped,

  /// The bytes after the last whole frame, dropped.
  int tornBytes,
});

/// The journal's entries in [JournalFrames], one entry a frame. Times are
/// ISO 8601, which keeps whether a time was UTC, so a record reads back
/// equal to the one written.
final class JournalCodec {
  /// A codec that writes and reads results through [resultCodecs].
  JournalCodec(Iterable<TransferResultCodec> resultCodecs)
    : _results = {for (final codec in resultCodecs) codec.kind: codec};

  final Map<String, TransferResultCodec> _results;

  // --- Frames ----------------------------------------------------------------

  /// [entries] as frames, one after another.
  Uint8List encode(Iterable<JournalEntry> entries) =>
      JournalFrames.encode(entries.map(_entryToJson));

  /// The entries in [bytes], up to the first frame that is not whole.
  JournalRead decode(Uint8List bytes) {
    final read = JournalFrames.decode(bytes);
    final entries = <JournalEntry>[];
    var skipped = 0;
    for (final payload in read.payloads) {
      switch (_tryEntry(payload)) {
        case final entry?:
          entries.add(entry);
        case null:
          skipped++;
      }
    }
    return (entries: entries, skipped: skipped, tornBytes: read.tornBytes);
  }

  // --- Entries ---------------------------------------------------------------

  Map<String, Object?> _entryToJson(JournalEntry entry) => switch (entry) {
    JournalEntry$Header(:final generation) => {'header': generation},
    JournalEntry$Put(:final record) => {'put': _recordToJson(record)},
    JournalEntry$Remove(:final id) => {'remove': id.value},
  };

  /// The entry [payload] holds, or null when it cannot be read back.
  JournalEntry? _tryEntry(Object? payload) {
    try {
      return switch (payload) {
        {'header': final int generation} => JournalEntry$Header(generation),
        {'put': final Map<String, Object?> record} => JournalEntry$Put(
          _recordFromJson(record),
        ),
        {'remove': final String id} => JournalEntry$Remove(
          TransferId.parse(id),
        ),
        _ => null,
      };
    } on Object {
      // A whole frame that does not read back is a record of a version or
      // a result kind this build does not know; it is skipped, not torn.
      return null;
    }
  }

  // --- Records ---------------------------------------------------------------

  Map<String, Object?> _recordToJson(JournalRecord record) {
    final job = record.job;
    return {
      'id': job.id.value,
      'direction': job.direction.name,
      'durability': job.durability.name,
      'priority': job.priority.name,
      'tag': ?job.tag,
      'key': ?job.key?.encoded,
      'resumeOnStart': job.resumeOnStart,
      'createdAt': job.createdAt.toIso8601String(),
      'updatedAt': job.updatedAt.toIso8601String(),
      'state': _stateToJson(job.state),
      if (record.upload case final upload?) 'upload': _uploadToJson(upload),
      'envelopeHandle': ?record.envelopeHandle,
      'lastProgressAt': ?record.lastProgressAt?.toIso8601String(),
    };
  }

  JournalRecord _recordFromJson(Map<String, Object?> json) => JournalRecord(
    job: TransferJob(
      id: TransferId.parse(json['id']! as String),
      direction: TransferDirection.values.byName(json['direction']! as String),
      durability: TransferDurability.values.byName(
        json['durability']! as String,
      ),
      priority: RequestPriority.values.byName(json['priority']! as String),
      tag: json['tag'] as String?,
      key: switch (json['key']) {
        final String encoded => MediaKey.parse(encoded),
        _ => null,
      },
      resumeOnStart: json['resumeOnStart']! as bool,
      createdAt: DateTime.parse(json['createdAt']! as String),
      updatedAt: DateTime.parse(json['updatedAt']! as String),
      state: _stateFromJson(json['state']! as Map<String, Object?>),
    ),
    upload: switch (json['upload']) {
      final Map<String, Object?> upload => _uploadFromJson(upload),
      _ => null,
    },
    envelopeHandle: json['envelopeHandle'] as String?,
    lastProgressAt: switch (json['lastProgressAt']) {
      final String time => DateTime.parse(time),
      _ => null,
    },
  );

  // --- Uploads ---------------------------------------------------------------

  /// A part is `[index]`, or `[index, receipt]` when the remote end gave
  /// one: the list stays short for a transport that gives none.
  Map<String, Object?> _uploadToJson(JournalUpload upload) => {
    'source': {
      'path': upload.source.path,
      'size': upload.source.size,
      'growing': upload.source.growing,
      'fingerprint': upload.source.fingerprint,
      'modified': ?upload.source.modified?.toIso8601String(),
    },
    'transportId': upload.transportId,
    'lane': upload.lane.name,
    'partSize': upload.partSize,
    'fileName': ?upload.fileName,
    'contentType': ?upload.contentType,
    'resumeToken': ?upload.resumeToken,
    'resumeExpiresAt': ?upload.resumeExpiresAt?.toIso8601String(),
    if (upload.parts.isNotEmpty)
      'parts': [
        for (final MapEntry(key: index, value: receipt) in upload.parts.entries)
          [index, ?receipt],
      ],
    if (upload.highWaterMark != 0) 'highWaterMark': upload.highWaterMark,
    if (upload.owner case final owner?)
      'owner': {
        'job': owner.job,
        'item': owner.itemId,
        'role': owner.role.name,
      },
  };

  JournalUpload _uploadFromJson(Map<String, Object?> json) {
    final source = json['source']! as Map<String, Object?>;
    return JournalUpload(
      source: JournalSource(
        path: source['path']! as String,
        size: source['size']! as int,
        growing: source['growing']! as bool,
        fingerprint: source['fingerprint']! as String,
        modified: switch (source['modified']) {
          final String modified => DateTime.parse(modified),
          _ => null,
        },
      ),
      transportId: json['transportId']! as String,
      lane: UploadLane.values.byName(json['lane']! as String),
      partSize: json['partSize']! as int,
      fileName: json['fileName'] as String?,
      contentType: json['contentType'] as String?,
      resumeToken: json['resumeToken'] as String?,
      resumeExpiresAt: switch (json['resumeExpiresAt']) {
        final String expiry => DateTime.parse(expiry),
        _ => null,
      },
      parts: {
        for (final part in (json['parts'] as List<Object?>?) ?? const [])
          if (part case [final int index, ...final rest])
            index: rest.isEmpty ? null : rest.first! as String,
      },
      highWaterMark: json['highWaterMark'] as int? ?? 0,
      owner: switch (json['owner']) {
        {
          'job': final String job,
          'item': final String item,
          'role': final String role,
        } =>
          JournalUploadOwner(
            job: job,
            itemId: item,
            role: UploadRole.values.byName(role),
          ),
        _ => null,
      },
    );
  }

  // --- States ----------------------------------------------------------------

  Map<String, Object?> _stateToJson(TransferState state) => switch (state) {
    TransferState$Queued(:final total) => {'is': 'queued', 'total': ?total},
    TransferState$Running(:final done, :final total, :final estimated) => {
      'is': 'running',
      'done': done,
      'total': ?total,
      if (estimated) 'estimated': true,
    },
    TransferState$Paused(:final reason, :final done, :final total) => {
      'is': 'paused',
      'reason': reason.name,
      'done': done,
      'total': ?total,
    },
    TransferState$Failed(
      :final kind,
      :final retryable,
      :final done,
      :final total,
    ) =>
      {
        'is': 'failed',
        'kind': kind.name,
        'retryable': retryable,
        'done': done,
        'total': ?total,
      },
    TransferState$Completed(:final result) => {
      'is': 'completed',
      'result': _resultToJson(result),
    },
  };

  TransferState _stateFromJson(Map<String, Object?> json) {
    final total = json['total'] as int?;
    final done = json['done'] as int? ?? 0;
    return switch (json['is']) {
      'queued' => TransferState.queued(total: total),
      'running' => TransferState.running(
        done: done,
        total: total,
        estimated: json['estimated'] as bool? ?? false,
      ),
      'paused' => TransferState.paused(
        reason: PauseReason.values.byName(json['reason']! as String),
        done: done,
        total: total,
      ),
      'failed' => TransferState.failed(
        kind: TransferFailureKind.values.byName(json['kind']! as String),
        retryable: json['retryable']! as bool,
        done: done,
        total: total,
      ),
      'completed' => TransferState.completed(
        _resultFromJson(json['result']! as Map<String, Object?>),
      ),
      final other => throw FormatException('Unknown transfer state.', other),
    };
  }

  Map<String, Object?> _resultToJson(TransferResult result) {
    for (final codec in _results.values) {
      if (codec.encode(result) case final json?) {
        return {'kind': codec.kind, 'value': json};
      }
    }
    throw ArgumentError.value(
      result,
      'result',
      'has no TransferResultCodec: each result kind brings one',
    );
  }

  TransferResult _resultFromJson(Map<String, Object?> json) {
    final kind = json['kind']! as String;
    final codec =
        _results[kind] ??
        (throw FormatException('No codec for the result kind.', kind));
    return codec.decode(json['value']! as Map<String, Object?>);
  }
}
