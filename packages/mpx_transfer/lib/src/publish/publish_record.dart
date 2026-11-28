import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_transfer/src/job/transfer_id.dart';
import 'package:mpx_transfer/src/job/transfer_job.dart';
import 'package:mpx_transfer/src/journal/json_fields.dart';
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

/// [PublishRecord] ↔ the JSON object a publish journal frames.
///
/// The journal's frame payload is `{"put": <record>}`, so a record is a
/// JSON object inside it: this codec stops at the map and the frames own
/// the text and the bytes ([Map] rather than [String], so the record is not
/// encoded twice).
///
/// ## Fields
///
/// | Key | Value | When |
/// |---|---|---|
/// | `v` | [version] | always |
/// | `id` | [PublishRecord.id] | always |
/// | `tag`, `publisher`, `transport`, `orderingGroup` | string | when set |
/// | `payload` | base64 of [PublishRecord.payload] | always |
/// | `durability`, `failurePolicy` | enum name | always |
/// | `groupOrder` | integer | when set |
/// | `hold`, `committed`, `awaitingOwner` | `true` | when true |
/// | `idempotencyKey` | string | always |
/// | `keyFromRequest` | flag | always |
/// | `createdAt`, `updatedAt` | ISO 8601 | always |
/// | `attempts` | integer | always |
/// | `reuploads` | integer | when above 0 |
/// | `aliases` | item id to encoded `MediaKey` | when not empty |
/// | `items` | list of items | always |
/// | `end` | `{"is": "completed", "result"?}` or `{"is": "failed", "stage", "reason", "retryable"}` | once ended |
/// | `progress` | number | when above 0 |
///
/// An item is `{itemId, key, fingerprint?, fileName?, source, progress}`.
/// Its `source` is `{"is": "prepare", input, intent}`, `{"is": "prepared",
/// media}` or `{"is": "remote"}`, the inner values in the form of
/// [PreparationInputCodec], [PreparationIntentCodec] and
/// [PreparedMediaCodec]. Its `progress` is tagged by `is`, one tag per
/// [ItemProgress] variant: `waiting`; `prepared` (`media`,
/// `reuseKey?`); `uploading` (`media`, `file`, `thumbnail?`, `reuseKey?`);
/// `uploaded` (`file?`, `thumbnail?` as [RemoteRef]s, `reused` when true,
/// `media?`, `reuseKey?`, `uploads` when not empty); `failed` (`stage`,
/// `reason`, `retryable`, `before?`, itself a progress).
///
/// ## Encoding
///
/// A field at its default (null, false, 0, empty) is left out, so a record
/// stays small in a log that rewrites it at every change. A record whose
/// [PublishRecord.end] is not an end (a job state other than completed or
/// failed) throws an [ArgumentError].
///
/// ## Decoding
///
/// A missing field reads as its default where the encoder leaves the
/// default out; every other field is required. A missing required field,
/// a field of the wrong type, an unknown enum name or `is` tag, a time
/// that is not ISO 8601 and a key that is not an encoded key each throw a
/// [FormatException] naming the field, its source the object read. The
/// journal skips such a record, as it skips one of a newer version.
///
/// ## Versioning
///
/// One version, [version], written under `v`; a record of another version
/// is refused with a [FormatException]. A new field that an older record
/// lacks reads as its default within the same version; a change an older
/// build would misread takes a new version.
///
/// Internal to the package.
@internal
final class PublishRecordCodec
    extends Codec<PublishRecord, Map<String, Object?>> {
  /// The record ↔ JSON object codec.
  const PublishRecordCodec();

  /// The version written, and the only one read.
  static const int version = 1;

  @override
  Converter<PublishRecord, Map<String, Object?>> get encoder =>
      const _PublishRecordEncoder();

  @override
  Converter<Map<String, Object?>, PublishRecord> get decoder =>
      const _PublishRecordDecoder();
}

/// Field names shared by both directions.
abstract final class _Key {
  static const String version = 'v';
  static const String id = 'id';
  static const String tag = 'tag';
  static const String publisher = 'publisher';
  static const String transport = 'transport';
  static const String payload = 'payload';
  static const String durability = 'durability';
  static const String failurePolicy = 'failurePolicy';
  static const String orderingGroup = 'orderingGroup';
  static const String groupOrder = 'groupOrder';
  static const String hold = 'hold';
  static const String committed = 'committed';
  static const String awaitingOwner = 'awaitingOwner';
  static const String idempotencyKey = 'idempotencyKey';
  static const String keyFromRequest = 'keyFromRequest';
  static const String createdAt = 'createdAt';
  static const String updatedAt = 'updatedAt';
  static const String attempts = 'attempts';
  static const String reuploads = 'reuploads';
  static const String aliases = 'aliases';
  static const String items = 'items';
  static const String end = 'end';
  static const String progress = 'progress';

  // An item.
  static const String itemId = 'itemId';
  static const String key = 'key';
  static const String fingerprint = 'fingerprint';
  static const String fileName = 'fileName';
  static const String source = 'source';
  static const String input = 'input';
  static const String intent = 'intent';
  static const String media = 'media';
  static const String reuseKey = 'reuseKey';
  static const String file = 'file';
  static const String thumbnail = 'thumbnail';
  static const String reused = 'reused';
  static const String uploads = 'uploads';
  static const String before = 'before';

  // An end or a failure.
  static const String result = 'result';
  static const String stage = 'stage';
  static const String reason = 'reason';
  static const String retryable = 'retryable';

  /// The tag of a tagged object: a source, a progress, an end.
  static const String variant = 'is';
}

/// The `is` tags, by what they tag.
abstract final class _Is {
  static const String prepare = 'prepare';
  static const String prepared = 'prepared';
  static const String remote = 'remote';
  static const String waiting = 'waiting';
  static const String uploading = 'uploading';
  static const String uploaded = 'uploaded';
  static const String failed = 'failed';
  static const String completed = 'completed';
}

final class _PublishRecordEncoder
    extends Converter<PublishRecord, Map<String, Object?>> {
  const _PublishRecordEncoder();

  @override
  Map<String, Object?> convert(PublishRecord input) => {
    _Key.version: PublishRecordCodec.version,
    _Key.id: input.id.value,
    _Key.tag: ?input.tag,
    _Key.publisher: ?input.publisher,
    _Key.transport: ?input.transport,
    _Key.payload: base64Encode(input.payload),
    _Key.durability: input.durability.name,
    _Key.failurePolicy: input.failurePolicy.name,
    _Key.orderingGroup: ?input.orderingGroup,
    _Key.groupOrder: ?input.groupOrder,
    if (input.hold) _Key.hold: true,
    if (input.committed) _Key.committed: true,
    if (input.awaitingOwner) _Key.awaitingOwner: true,
    _Key.idempotencyKey: input.idempotencyKey,
    _Key.keyFromRequest: input.keyFromRequest,
    _Key.createdAt: input.createdAt.toIso8601String(),
    _Key.updatedAt: input.updatedAt.toIso8601String(),
    _Key.attempts: input.attempts,
    if (input.reuploads > 0) _Key.reuploads: input.reuploads,
    if (input.aliases.isNotEmpty)
      _Key.aliases: {
        for (final MapEntry(:key, :value) in input.aliases.entries)
          key: value.encoded,
      },
    _Key.items: [for (final item in input.items) _item(item)],
    if (input.end case final end?) _Key.end: _end(end),
    if (input.progress > 0) _Key.progress: input.progress,
  };

  static Map<String, Object?> _item(PublishItemRecord record) {
    final item = record.item;
    return {
      _Key.itemId: item.itemId,
      _Key.key: item.key.encoded,
      _Key.fingerprint: ?item.fingerprint,
      _Key.fileName: ?item.fileName,
      _Key.source: switch (item.source) {
        PublishSource$Prepare(:final input, :final intent) => {
          _Key.variant: _Is.prepare,
          _Key.input: const PreparationInputCodec().encode(input),
          _Key.intent: const PreparationIntentCodec().encode(intent),
        },
        PublishSource$Prepared(:final media) => {
          _Key.variant: _Is.prepared,
          _Key.media: const PreparedMediaCodec().encode(media),
        },
        PublishSource$Remote() => {_Key.variant: _Is.remote},
      },
      _Key.progress: _progress(record.progress),
    };
  }

  static Map<String, Object?> _progress(ItemProgress progress) =>
      switch (progress) {
        ItemProgress$Waiting() => {_Key.variant: _Is.waiting},
        ItemProgress$Prepared(:final media, :final reuseKey) => {
          _Key.variant: _Is.prepared,
          _Key.media: const PreparedMediaCodec().encode(media),
          _Key.reuseKey: ?reuseKey?.encoded,
        },
        ItemProgress$Uploading(
          :final media,
          :final file,
          :final thumbnail,
          :final reuseKey,
        ) =>
          {
            _Key.variant: _Is.uploading,
            _Key.media: const PreparedMediaCodec().encode(media),
            _Key.file: file.value,
            _Key.thumbnail: ?thumbnail?.value,
            _Key.reuseKey: ?reuseKey?.encoded,
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
            _Key.variant: _Is.uploaded,
            _Key.file: ?_ref(file),
            _Key.thumbnail: ?_ref(thumbnail),
            if (reused) _Key.reused: true,
            if (media != null)
              _Key.media: const PreparedMediaCodec().encode(media),
            _Key.reuseKey: ?reuseKey?.encoded,
            if (uploads.isNotEmpty)
              _Key.uploads: [for (final upload in uploads) upload.value],
          },
        ItemProgress$Failed(
          :final stage,
          :final reason,
          :final retryable,
          :final before,
        ) =>
          {
            _Key.variant: _Is.failed,
            _Key.stage: stage.name,
            _Key.reason: reason,
            _Key.retryable: retryable,
            if (before != null) _Key.before: _progress(before),
          },
      };

  static Map<String, Object?> _end(PublishJobState end) => switch (end) {
    PublishJobState$Completed(:final result) => {
      _Key.variant: _Is.completed,
      if (result != null) _Key.result: base64Encode(result),
    },
    PublishJobState$Failed(:final stage, :final reason, :final retryable) => {
      _Key.variant: _Is.failed,
      _Key.stage: stage.name,
      _Key.reason: reason,
      _Key.retryable: retryable,
    },
    PublishJobState$Preparing() ||
    PublishJobState$Uploading() ||
    PublishJobState$Publishing() ||
    PublishJobState$AwaitingPublisher() ||
    PublishJobState$AwaitingOwner() ||
    PublishJobState$Paused() => throw ArgumentError.value(
      end,
      'end',
      'is not an end of a job',
    ),
  };

  static Map<String, Object?>? _ref(RemoteRef? ref) => switch (ref) {
    final ref? => RemoteRef.codec.encode(ref),
    null => null,
  };
}

final class _PublishRecordDecoder
    extends Converter<Map<String, Object?>, PublishRecord> {
  const _PublishRecordDecoder();

  @override
  PublishRecord convert(Map<String, Object?> input) {
    final json = JsonFields(input);
    if (input[_Key.version] != PublishRecordCodec.version) {
      throw FormatException(
        'Unknown publish record version "${input[_Key.version]}".',
        input,
      );
    }
    return PublishRecord(
      id: PublishJobId.parse(json.string(_Key.id)),
      tag: json.optionalString(_Key.tag),
      publisher: json.optionalString(_Key.publisher),
      transport: json.optionalString(_Key.transport),
      payload: _bytes(json, _Key.payload),
      durability: json.byName(TransferDurability.values, _Key.durability),
      failurePolicy: json.byName(
        PublishFailurePolicy.values,
        _Key.failurePolicy,
      ),
      orderingGroup: json.optionalString(_Key.orderingGroup),
      groupOrder: json.optionalInteger(_Key.groupOrder),
      hold: json.optionalFlag(_Key.hold),
      committed: json.optionalFlag(_Key.committed),
      awaitingOwner: json.optionalFlag(_Key.awaitingOwner),
      idempotencyKey: json.string(_Key.idempotencyKey),
      keyFromRequest: json.flag(_Key.keyFromRequest),
      createdAt: json.time(_Key.createdAt),
      updatedAt: json.time(_Key.updatedAt),
      attempts: json.integer(_Key.attempts),
      reuploads: json.optionalInteger(_Key.reuploads) ?? 0,
      aliases: switch (json.optionalObject(_Key.aliases)) {
        final aliases? => {
          for (final itemId in aliases.json.keys)
            itemId: _mediaKey(aliases, itemId),
        },
        null => const {},
      },
      items: [for (final item in json.objects(_Key.items)) _item(item)],
      end: switch (json.optionalObject(_Key.end)) {
        final end? => _end(end),
        null => null,
      },
      progress: json.optionalNumber(_Key.progress) ?? 0,
    );
  }

  static PublishItemRecord _item(JsonFields json) => PublishItemRecord(
    PublishItem(
      itemId: json.string(_Key.itemId),
      key: _mediaKey(json, _Key.key),
      fingerprint: json.optionalString(_Key.fingerprint),
      fileName: json.optionalString(_Key.fileName),
      source: _source(json.object(_Key.source)),
    ),
    _progress(json.object(_Key.progress)),
  );

  static PublishSource _source(JsonFields json) =>
      switch (json.string(_Key.variant)) {
        _Is.prepare => PublishSource.prepare(
          const PreparationInputCodec().decode(json.object(_Key.input).json),
          const PreparationIntentCodec().decode(json.object(_Key.intent).json),
        ),
        _Is.prepared => PublishSource.prepared(_media(json)),
        _Is.remote => const PublishSource.remote(),
        final other => throw FormatException(
          'Unknown source "$other" under "${_Key.variant}".',
          json.json,
        ),
      };

  static ItemProgress _progress(JsonFields json) =>
      switch (json.string(_Key.variant)) {
        _Is.waiting => const ItemProgress$Waiting(),
        _Is.prepared => ItemProgress$Prepared(
          _media(json),
          reuseKey: _reuseKey(json),
        ),
        _Is.uploading => ItemProgress$Uploading(
          _media(json),
          file: TransferId.parse(json.string(_Key.file)),
          thumbnail: switch (json.optionalString(_Key.thumbnail)) {
            final id? => TransferId.parse(id),
            null => null,
          },
          reuseKey: _reuseKey(json),
        ),
        _Is.uploaded => ItemProgress$Uploaded(
          file: _ref(json, _Key.file),
          thumbnail: _ref(json, _Key.thumbnail),
          reused: json.optionalFlag(_Key.reused),
          media: switch (json.optionalObject(_Key.media)) {
            final media? => const PreparedMediaCodec().decode(media.json),
            null => null,
          },
          reuseKey: _reuseKey(json),
          uploads: [
            for (final upload in json.optionalStrings(_Key.uploads))
              TransferId.parse(upload),
          ],
        ),
        _Is.failed => ItemProgress$Failed(
          stage: json.byName(PublishStage.values, _Key.stage),
          reason: json.string(_Key.reason),
          retryable: json.flag(_Key.retryable),
          before: switch (json.optionalObject(_Key.before)) {
            final before? => _progress(before),
            null => null,
          },
        ),
        final other => throw FormatException(
          'Unknown progress "$other" under "${_Key.variant}".',
          json.json,
        ),
      };

  static PublishJobState _end(JsonFields json) =>
      switch (json.string(_Key.variant)) {
        _Is.completed => PublishJobState.completed(switch (json.optionalString(
          _Key.result,
        )) {
          final result? => _base64(json, _Key.result, result),
          null => null,
        }),
        _Is.failed => PublishJobState.failed(
          stage: json.byName(PublishStage.values, _Key.stage),
          reason: json.string(_Key.reason),
          retryable: json.flag(_Key.retryable),
        ),
        final other => throw FormatException(
          'Unknown end "$other" under "${_Key.variant}".',
          json.json,
        ),
      };

  // --- Read shapes -----------------------------------------------------------

  /// The required prepared file under `media`.
  static PreparedMedia _media(JsonFields json) =>
      const PreparedMediaCodec().decode(json.object(_Key.media).json);

  static ReuseKey? _reuseKey(JsonFields json) =>
      switch (json.optionalString(_Key.reuseKey)) {
        final encoded? => ReuseKey.decode(encoded),
        null => null,
      };

  static RemoteRef? _ref(JsonFields json, String key) =>
      switch (json.optionalObject(key)) {
        final ref? => RemoteRef.codec.decode(ref.json) as RemoteRef,
        null => null,
      };

  /// The encoded `MediaKey` under [key], its error naming the field.
  static MediaKey _mediaKey(JsonFields json, String key) {
    final encoded = json.string(key);
    return MediaKey.tryParse(encoded) ??
        (throw FormatException(
          'Expected a media key under "$key".',
          json.json,
        ));
  }

  static Uint8List _bytes(JsonFields json, String key) =>
      _base64(json, key, json.string(key));

  static Uint8List _base64(JsonFields json, String key, String value) {
    try {
      return base64Decode(value);
    } on FormatException {
      throw FormatException('Expected base64 under "$key".', json.json);
    }
  }
}
