import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_transfer/src/job/transfer_id.dart';
import 'package:mpx_transfer/src/job/transfer_job.dart';
import 'package:mpx_transfer/src/publish/publish_request.dart';
import 'package:mpx_transfer/src/publish/publish_state.dart';
import 'package:mpx_transfer/src/reuse/reuse_table.dart';
import 'package:mpx_transfer/src/upload/remote_ref.dart';

/// A publish job as its journal keeps it: the request, the engine's
/// idempotency key, each item's progress and, once the job is done, how it
/// ended.
///
/// What is not here is not kept: a preparation under way, an upload's
/// bytes in flight (the upload's own journal record keeps its parts).
/// Internal to the package.
@immutable
final class PublishRecord {
  /// A record; see the fields.
  PublishRecord({
    required this.id,
    required this.payload,
    required this.durability,
    required this.failurePolicy,
    required this.idempotencyKey,
    required this.keyFromRequest,
    required this.createdAt,
    required this.updatedAt,
    required List<PublishItemRecord> items,
    this.tag,
    this.publisher,
    this.transport,
    this.orderingGroup,
    this.groupOrder,
    this.hold = false,
    this.committed = false,
    this.awaitingOwner = false,
    this.attempts = 0,
    this.reuploads = 0,
    Map<String, MediaKey> aliases = const {},
    this.end,
    this.progress = 0,
  }) : items = List.unmodifiable(items),
       aliases = Map.unmodifiable(aliases);

  /// The job's id.
  final PublishJobId id;

  /// The host's tag.
  final String? tag;

  /// The publisher's id; null for an upload with no publisher.
  final String? publisher;

  /// The transport the items go through; null when none was needed.
  final String? transport;

  /// The host's bytes for the publisher.
  final Uint8List payload;

  /// The durability of the job's uploads.
  final TransferDurability durability;

  /// What one failed item does to the job.
  final PublishFailurePolicy failurePolicy;

  /// The job's ordering group, when it has one.
  final String? orderingGroup;

  /// The job's place in [orderingGroup]'s line: it publishes after every
  /// job of the group with a lower place that is still on its way. Taken
  /// when the job joins the line (made, committed, or retried after it
  /// failed), so a job that joins again goes to the end; null outside a
  /// line (no group, or held and not committed yet).
  final int? groupOrder;

  /// Whether the job publishes only once committed.
  final bool hold;

  /// Whether the host committed a held job.
  final bool committed;

  /// Whether the job's last item was removed and it waits for its owner to
  /// commit or cancel it. A job made with no items never waits so.
  final bool awaitingOwner;

  /// The key every publish attempt carries.
  final String idempotencyKey;

  /// Whether [idempotencyKey] is the request's own.
  final bool keyFromRequest;

  /// When the job was made.
  final DateTime createdAt;

  /// When the record last changed.
  final DateTime updatedAt;

  /// The items, in the request's order.
  final List<PublishItemRecord> items;

  /// The publish attempts begun so far.
  final int attempts;

  /// The `reuploadItems` answers honoured so far: at most one.
  final int reuploads;

  /// The server keys of a completed job whose aliases are not all applied
  /// yet, item id to server key; empty otherwise. Kept with the completion,
  /// so a kill before the aliases applied applies them at the next start.
  final Map<String, MediaKey> aliases;

  /// How the job ended: completed or failed; null while it goes on.
  final PublishJobState? end;

  /// The job's progress as last shown when the record was written: what a
  /// restart's progress starts from, so the ring does not go back.
  final double progress;

  /// Whether the job goes on: it has not ended.
  bool get isRunning => end == null;

  /// This record with the given parts replaced; [clearEnd] reopens an
  /// ended job.
  PublishRecord copyWith({
    List<PublishItemRecord>? items,
    Uint8List? payload,
    int? groupOrder,
    bool? committed,
    bool? awaitingOwner,
    int? attempts,
    int? reuploads,
    Map<String, MediaKey>? aliases,
    PublishJobState? end,
    bool clearEnd = false,
    DateTime? updatedAt,
    double? progress,
  }) => PublishRecord(
    id: id,
    tag: tag,
    publisher: publisher,
    transport: transport,
    payload: payload ?? this.payload,
    durability: durability,
    failurePolicy: failurePolicy,
    orderingGroup: orderingGroup,
    groupOrder: groupOrder ?? this.groupOrder,
    hold: hold,
    committed: committed ?? this.committed,
    awaitingOwner: awaitingOwner ?? this.awaitingOwner,
    idempotencyKey: idempotencyKey,
    keyFromRequest: keyFromRequest,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    items: items ?? this.items,
    attempts: attempts ?? this.attempts,
    reuploads: reuploads ?? this.reuploads,
    aliases: aliases ?? this.aliases,
    end: clearEnd ? null : end ?? this.end,
    progress: progress ?? this.progress,
  );

  /// This record with item [itemId]'s progress replaced.
  PublishRecord withItem(String itemId, ItemProgress progress, DateTime now) =>
      copyWith(
        items: [
          for (final item in items)
            item.item.itemId == itemId
                ? PublishItemRecord(item.item, progress)
                : item,
        ],
        updatedAt: now,
      );
}

/// One item of a [PublishRecord]: the host's item and how far it got.
@immutable
final class PublishItemRecord {
  /// Item [item], as far as [progress].
  const PublishItemRecord(this.item, this.progress);

  /// The host's item.
  final PublishItem item;

  /// How far it got.
  final ItemProgress progress;
}

/// How far an item got, as the journal keeps it.
@immutable
sealed class ItemProgress {
  const ItemProgress();
}

/// Not prepared yet; a preparation under way at a kill starts over.
final class ItemProgress$Waiting extends ItemProgress {
  /// Not prepared yet.
  const ItemProgress$Waiting();
}

/// Prepared ([media]), its uploads not made yet. [reuseKey] is what the
/// reuse table stores its references under, when it has one.
final class ItemProgress$Prepared extends ItemProgress {
  /// Prepared as [media].
  const ItemProgress$Prepared(this.media, {this.reuseKey});

  /// The prepared file.
  final PreparedMedia media;

  /// The reuse table's key for the item's source, when it has one.
  final ReuseKey? reuseKey;
}

/// Uploading [media] as upload [file], and its thumbnail as [thumbnail]
/// when the transport takes it separately.
final class ItemProgress$Uploading extends ItemProgress {
  /// Uploading [media].
  const ItemProgress$Uploading(
    this.media, {
    required this.file,
    this.thumbnail,
    this.reuseKey,
  });

  /// The prepared file.
  final PreparedMedia media;

  /// The file's upload.
  final TransferId file;

  /// The thumbnail's upload, when it goes separately.
  final TransferId? thumbnail;

  /// The reuse table's key for the item's source, when it has one.
  final ReuseKey? reuseKey;
}

/// On the remote end; [reused] when the reuse table answered it. [media]
/// and [reuseKey] are kept for a `reuploadItems` answer: the file to send
/// again, and the reuse entry to drop.
final class ItemProgress$Uploaded extends ItemProgress {
  /// Uploaded to [file] and [thumbnail].
  const ItemProgress$Uploaded({
    this.file,
    this.thumbnail,
    this.reused = false,
    this.media,
    this.reuseKey,
    this.uploads = const [],
  });

  /// The completed uploads that sent the item, its file's and its
  /// thumbnail's: what a cancel of the job or a removal of the item drops.
  /// Empty for a remote item or a reuse hit.
  final List<TransferId> uploads;

  /// The prepared file that was sent; null for a remote item or a reuse
  /// hit, which sent nothing.
  final PreparedMedia? media;

  /// The reuse table's key for the item's source, when it has one.
  final ReuseKey? reuseKey;

  /// Where the file lives; null for a remote item.
  final RemoteRef? file;

  /// Where the thumbnail lives, when it went separately.
  final RemoteRef? thumbnail;

  /// Whether the reuse table answered the item.
  final bool reused;
}

/// Failed at [stage]; [before] is where a retry takes the item back to.
final class ItemProgress$Failed extends ItemProgress {
  /// Failed at [stage] for [reason].
  const ItemProgress$Failed({
    required this.stage,
    required this.reason,
    required this.retryable,
    this.before,
  });

  /// The progress the item had when it failed, prepared or uploading, so a
  /// retry keeps the finished preparation and the journaled uploads; null
  /// to start the item over.
  final ItemProgress? before;

  /// The step that failed.
  final PublishStage stage;

  /// A short code for why.
  final String reason;

  /// Whether a retry may succeed.
  final bool retryable;
}

/// The JSON form of a [PublishRecord]; one version, with an unknown one
/// refused as a [FormatException].
@internal
abstract final class PublishRecordCodec {
  /// The version written, and the only one read.
  static const int version = 1;

  /// [record] as JSON.
  static Map<String, Object?> encode(PublishRecord record) => {
    'v': version,
    'id': record.id.value,
    'tag': ?record.tag,
    'publisher': ?record.publisher,
    'transport': ?record.transport,
    'payload': base64Encode(record.payload),
    'durability': record.durability.name,
    'failurePolicy': record.failurePolicy.name,
    'orderingGroup': ?record.orderingGroup,
    'groupOrder': ?record.groupOrder,
    if (record.hold) 'hold': true,
    if (record.committed) 'committed': true,
    if (record.awaitingOwner) 'awaitingOwner': true,
    'idempotencyKey': record.idempotencyKey,
    'keyFromRequest': record.keyFromRequest,
    'createdAt': record.createdAt.toIso8601String(),
    'updatedAt': record.updatedAt.toIso8601String(),
    'attempts': record.attempts,
    if (record.reuploads > 0) 'reuploads': record.reuploads,
    if (record.aliases.isNotEmpty)
      'aliases': {
        for (final MapEntry(:key, :value) in record.aliases.entries)
          key: value.encoded,
      },
    'items': [for (final item in record.items) _itemToJson(item)],
    if (record.end case final end?) 'end': _endToJson(end),
    if (record.progress > 0) 'progress': record.progress,
  };

  /// The record [json] holds.
  static PublishRecord decode(Map<String, Object?> json) {
    if (json['v'] != version) {
      throw FormatException('Unknown publish record version "${json['v']}".');
    }
    return PublishRecord(
      id: PublishJobId.parse(json['id']! as String),
      tag: json['tag'] as String?,
      publisher: json['publisher'] as String?,
      transport: json['transport'] as String?,
      payload: base64Decode(json['payload']! as String),
      durability: TransferDurability.values.byName(
        json['durability']! as String,
      ),
      failurePolicy: PublishFailurePolicy.values.byName(
        json['failurePolicy']! as String,
      ),
      orderingGroup: json['orderingGroup'] as String?,
      groupOrder: json['groupOrder'] as int?,
      hold: json['hold'] as bool? ?? false,
      committed: json['committed'] as bool? ?? false,
      awaitingOwner: json['awaitingOwner'] as bool? ?? false,
      idempotencyKey: json['idempotencyKey']! as String,
      keyFromRequest: json['keyFromRequest']! as bool,
      createdAt: DateTime.parse(json['createdAt']! as String),
      updatedAt: DateTime.parse(json['updatedAt']! as String),
      attempts: json['attempts']! as int,
      reuploads: json['reuploads'] as int? ?? 0,
      aliases: {
        for (final MapEntry(:key, :value)
            in (json['aliases'] as Map<String, Object?>? ?? const {}).entries)
          key: MediaKey.parse(value! as String),
      },
      items: [
        for (final item in json['items']! as List<Object?>)
          _itemFromJson(item! as Map<String, Object?>),
      ],
      end: switch (json['end']) {
        final Map<String, Object?> end => _endFromJson(end),
        _ => null,
      },
      progress: (json['progress'] as num?)?.toDouble() ?? 0,
    );
  }

  // --- Items -----------------------------------------------------------------

  static Map<String, Object?> _itemToJson(PublishItemRecord record) {
    final item = record.item;
    return {
      'itemId': item.itemId,
      'key': item.key.encoded,
      'fingerprint': ?item.fingerprint,
      'fileName': ?item.fileName,
      'source': switch (item.source) {
        PublishSource$Prepare(:final input, :final intent) => {
          'is': 'prepare',
          'input': PreparationEncoding.encodeInput(input),
          'intent': PreparationEncoding.encodeIntent(intent),
        },
        PublishSource$Prepared(:final media) => {
          'is': 'prepared',
          'media': PreparationEncoding.encodePrepared(media),
        },
        PublishSource$Remote() => {'is': 'remote'},
      },
      'progress': _progressToJson(record.progress),
    };
  }

  static Map<String, Object?> _progressToJson(ItemProgress progress) =>
      switch (progress) {
        ItemProgress$Waiting() => {'is': 'waiting'},
        ItemProgress$Prepared(:final media, :final reuseKey) => {
          'is': 'prepared',
          'media': PreparationEncoding.encodePrepared(media),
          'reuseKey': ?reuseKey?.encoded,
        },
        ItemProgress$Uploading(
          :final media,
          :final file,
          :final thumbnail,
          :final reuseKey,
        ) =>
          {
            'is': 'uploading',
            'media': PreparationEncoding.encodePrepared(media),
            'file': file.value,
            'thumbnail': ?thumbnail?.value,
            'reuseKey': ?reuseKey?.encoded,
          },
        ItemProgress$Uploaded(
          :final file,
          :final thumbnail,
          :final reused,
          :final media,
          :final reuseKey,
          :final uploads,
        ) =>
          {
            'is': 'uploaded',
            'file': ?_refToJson(file),
            'thumbnail': ?_refToJson(thumbnail),
            if (reused) 'reused': true,
            if (media != null)
              'media': PreparationEncoding.encodePrepared(media),
            'reuseKey': ?reuseKey?.encoded,
            if (uploads.isNotEmpty)
              'uploads': [for (final upload in uploads) upload.value],
          },
        ItemProgress$Failed(
          :final stage,
          :final reason,
          :final retryable,
          :final before,
        ) =>
          {
            'is': 'failed',
            'stage': stage.name,
            'reason': reason,
            'retryable': retryable,
            if (before != null) 'before': _progressToJson(before),
          },
      };

  static PublishItemRecord _itemFromJson(Map<String, Object?> json) {
    final source = json['source']! as Map<String, Object?>;
    return PublishItemRecord(
      PublishItem(
        itemId: json['itemId']! as String,
        key: MediaKey.parse(json['key']! as String),
        fingerprint: json['fingerprint'] as String?,
        fileName: json['fileName'] as String?,
        source: switch (source['is']) {
          'prepare' => PublishSource.prepare(
            PreparationEncoding.decodeInput(
              source['input']! as Map<String, Object?>,
            ),
            PreparationEncoding.decodeIntent(
              source['intent']! as Map<String, Object?>,
            ),
          ),
          'prepared' => PublishSource.prepared(
            PreparationEncoding.decodePrepared(
              source['media']! as Map<String, Object?>,
            ),
          ),
          'remote' => const PublishSource.remote(),
          final other => throw FormatException('Unknown source "$other".'),
        },
      ),
      _progressFromJson(json['progress']! as Map<String, Object?>),
    );
  }

  static ItemProgress _progressFromJson(Map<String, Object?> progress) {
    ReuseKey? reuseKey() => switch (progress['reuseKey']) {
      final String encoded => ReuseKey.decode(encoded),
      _ => null,
    };
    PreparedMedia? media() => switch (progress['media']) {
      final Map<String, Object?> media => PreparationEncoding.decodePrepared(
        media,
      ),
      _ => null,
    };
    return switch (progress['is']) {
      'waiting' => const ItemProgress$Waiting(),
      'prepared' => ItemProgress$Prepared(media()!, reuseKey: reuseKey()),
      'uploading' => ItemProgress$Uploading(
        media()!,
        file: TransferId.parse(progress['file']! as String),
        thumbnail: switch (progress['thumbnail']) {
          final String id => TransferId.parse(id),
          _ => null,
        },
        reuseKey: reuseKey(),
      ),
      'uploaded' => ItemProgress$Uploaded(
        file: _refFromJson(progress['file']),
        thumbnail: _refFromJson(progress['thumbnail']),
        reused: progress['reused'] as bool? ?? false,
        media: media(),
        reuseKey: reuseKey(),
        uploads: [
          for (final upload
              in progress['uploads'] as List<Object?>? ?? const [])
            TransferId.parse(upload! as String),
        ],
      ),
      'failed' => ItemProgress$Failed(
        stage: PublishStage.values.byName(progress['stage']! as String),
        reason: progress['reason']! as String,
        retryable: progress['retryable']! as bool,
        before: switch (progress['before']) {
          final Map<String, Object?> before => _progressFromJson(before),
          _ => null,
        },
      ),
      final other => throw FormatException('Unknown progress "$other".'),
    };
  }

  // --- Ends and references ---------------------------------------------------

  static Map<String, Object?> _endToJson(PublishJobState end) => switch (end) {
    PublishJobState$Completed(:final result) => {
      'is': 'completed',
      if (result != null) 'result': base64Encode(result),
    },
    PublishJobState$Failed(:final stage, :final reason, :final retryable) => {
      'is': 'failed',
      'stage': stage.name,
      'reason': reason,
      'retryable': retryable,
    },
    _ => throw ArgumentError.value(end, 'end', 'is not an end of a job'),
  };

  static PublishJobState _endFromJson(Map<String, Object?> json) =>
      switch (json['is']) {
        'completed' => PublishJobState.completed(switch (json['result']) {
          final String result => base64Decode(result),
          _ => null,
        }),
        'failed' => PublishJobState.failed(
          stage: PublishStage.values.byName(json['stage']! as String),
          reason: json['reason']! as String,
          retryable: json['retryable']! as bool,
        ),
        final other => throw FormatException('Unknown end "$other".'),
      };

  static Map<String, Object?>? _refToJson(RemoteRef? ref) =>
      ref == null ? null : RemoteRef.codec.encode(ref);

  static RemoteRef? _refFromJson(Object? json) => switch (json) {
    final Map<String, Object?> map => RemoteRef.codec.decode(map) as RemoteRef,
    _ => null,
  };
}
