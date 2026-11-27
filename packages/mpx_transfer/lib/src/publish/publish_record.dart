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
    this.hold = false,
    this.attempts = 0,
    this.end,
  }) : items = List.unmodifiable(items);

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

  /// Whether the job publishes only once committed.
  final bool hold;

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

  /// How the job ended: completed or failed; null while it goes on.
  final PublishJobState? end;

  /// This record with the given parts replaced.
  PublishRecord copyWith({
    List<PublishItemRecord>? items,
    int? attempts,
    PublishJobState? end,
    DateTime? updatedAt,
  }) => PublishRecord(
    id: id,
    tag: tag,
    publisher: publisher,
    transport: transport,
    payload: payload,
    durability: durability,
    failurePolicy: failurePolicy,
    orderingGroup: orderingGroup,
    hold: hold,
    idempotencyKey: idempotencyKey,
    keyFromRequest: keyFromRequest,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    items: items ?? this.items,
    attempts: attempts ?? this.attempts,
    end: end ?? this.end,
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

/// On the remote end; [reused] when the reuse table answered it.
final class ItemProgress$Uploaded extends ItemProgress {
  /// Uploaded to [file] and [thumbnail].
  const ItemProgress$Uploaded({this.file, this.thumbnail, this.reused = false});

  /// Where the file lives; null for a remote item.
  final RemoteRef? file;

  /// Where the thumbnail lives, when it went separately.
  final RemoteRef? thumbnail;

  /// Whether the reuse table answered the item.
  final bool reused;
}

/// Failed at [stage].
final class ItemProgress$Failed extends ItemProgress {
  /// Failed at [stage] for [reason].
  const ItemProgress$Failed({
    required this.stage,
    required this.reason,
    required this.retryable,
  });

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
    if (record.hold) 'hold': true,
    'idempotencyKey': record.idempotencyKey,
    'keyFromRequest': record.keyFromRequest,
    'createdAt': record.createdAt.toIso8601String(),
    'updatedAt': record.updatedAt.toIso8601String(),
    'attempts': record.attempts,
    'items': [for (final item in record.items) _itemToJson(item)],
    if (record.end case final end?) 'end': _endToJson(end),
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
      hold: json['hold'] as bool? ?? false,
      idempotencyKey: json['idempotencyKey']! as String,
      keyFromRequest: json['keyFromRequest']! as bool,
      createdAt: DateTime.parse(json['createdAt']! as String),
      updatedAt: DateTime.parse(json['updatedAt']! as String),
      attempts: json['attempts']! as int,
      items: [
        for (final item in json['items']! as List<Object?>)
          _itemFromJson(item! as Map<String, Object?>),
      ],
      end: switch (json['end']) {
        final Map<String, Object?> end => _endFromJson(end),
        _ => null,
      },
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
      'progress': switch (record.progress) {
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
        ItemProgress$Uploaded(:final file, :final thumbnail, :final reused) => {
          'is': 'uploaded',
          'file': ?_refToJson(file),
          'thumbnail': ?_refToJson(thumbnail),
          if (reused) 'reused': true,
        },
        ItemProgress$Failed(:final stage, :final reason, :final retryable) => {
          'is': 'failed',
          'stage': stage.name,
          'reason': reason,
          'retryable': retryable,
        },
      },
    };
  }

  static PublishItemRecord _itemFromJson(Map<String, Object?> json) {
    final source = json['source']! as Map<String, Object?>;
    final progress = json['progress']! as Map<String, Object?>;
    ReuseKey? reuseKey() => switch (progress['reuseKey']) {
      final String encoded => ReuseKey.decode(encoded),
      _ => null,
    };
    PreparedMedia media() => PreparationEncoding.decodePrepared(
      progress['media']! as Map<String, Object?>,
    );
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
      switch (progress['is']) {
        'waiting' => const ItemProgress$Waiting(),
        'prepared' => ItemProgress$Prepared(media(), reuseKey: reuseKey()),
        'uploading' => ItemProgress$Uploading(
          media(),
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
        ),
        'failed' => ItemProgress$Failed(
          stage: PublishStage.values.byName(progress['stage']! as String),
          reason: progress['reason']! as String,
          retryable: progress['retryable']! as bool,
        ),
        final other => throw FormatException('Unknown progress "$other".'),
      },
    );
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
