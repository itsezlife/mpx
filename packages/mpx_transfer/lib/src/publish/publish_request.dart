import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:meta/meta.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_transfer/src/job/transfer_job.dart';

/// The identity of one publish job, issued by the engine when the job is
/// made: unique across runs, so an owner keeps it to find the job again
/// after a restart.
///
/// Opaque to hosts: compare it and keep it, never parse it. Diagnostics
/// carry it as the event's `jobId`.
extension type const PublishJobId._(String value) implements String {
  /// A new id: 128 random bits.
  factory PublishJobId.issue() => PublishJobId._('p-${_hex(16)}');

  /// The id written as [value], for an id read back from storage.
  const PublishJobId.parse(String value) : this._(value);
}

final Random _random = Random.secure();

String _hex(int bytes) => [
  for (var i = 0; i < bytes; i++)
    _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
].join();

/// What a publish job does when one of its items fails.
enum PublishFailurePolicy {
  /// The job fails; a retry repeats only what failed.
  wholeJob,

  /// The item is marked failed and the rest go on; publish waits until the
  /// host retries or removes the item.
  perItem,
}

/// A host's request for a publish job: prepare and upload [items] in order,
/// then hand their remote references and [payload] to the publisher
/// registered as [publisher].
///
/// [items] may be empty: a job with nothing to upload publishes at once.
@immutable
final class PublishRequest {
  /// A request; see the fields.
  PublishRequest({
    required List<PublishItem> items,
    required Uint8List payload,
    required this.publisher,
    this.tag,
    this.transport,
    this.durability = TransferDurability.system,
    this.failurePolicy = PublishFailurePolicy.wholeJob,
    this.orderingGroup,
    this.hold = false,
    this.idempotencyKey,
  }) : items = List.unmodifiable(items),
       payload = Uint8List.fromList(payload);

  /// The host's value for the job, carried as given and never read by the
  /// engine; its uploads carry it too.
  final String? tag;

  /// What to send, in order. Item ids are unique within a request.
  final List<PublishItem> items;

  /// The host's bytes for its publisher, opaque to the engine.
  final Uint8List payload;

  /// The id the publisher was registered under
  /// (`Transfers.registerPublisher`). A job whose publisher is not
  /// registered waits for it, after a restart too.
  final String publisher;

  /// The id of the upload transport the items go through; null for the
  /// first transport the facade was opened with.
  final String? transport;

  /// How hard the platform is asked to keep the job's uploads going:
  /// `system` by default.
  final TransferDurability durability;

  /// What one failed item does to the job.
  final PublishFailurePolicy failurePolicy;

  /// Jobs that share a group publish in the order they were made; null for
  /// none.
  final String? orderingGroup;

  /// Whether the job prepares and uploads but publishes only once the host
  /// commits it.
  final bool hold;

  /// The key every publish attempt carries, so the remote end applies one
  /// publish once; null for one the engine makes once and keeps.
  final String? idempotencyKey;

  @override
  bool operator ==(Object other) =>
      other is PublishRequest &&
      other.tag == tag &&
      listEquals(other.items, items) &&
      listEquals(other.payload, payload) &&
      other.publisher == publisher &&
      other.transport == transport &&
      other.durability == durability &&
      other.failurePolicy == failurePolicy &&
      other.orderingGroup == orderingGroup &&
      other.hold == hold &&
      other.idempotencyKey == idempotencyKey;

  @override
  int get hashCode => Object.hash(
    tag,
    Object.hashAll(items),
    Object.hashAll(payload),
    publisher,
    transport,
    durability,
    failurePolicy,
    orderingGroup,
    hold,
    idempotencyKey,
  );

  // The payload is the host's: only its size.
  @override
  String toString() =>
      'PublishRequest(${items.length} items, ${payload.length} B, '
      '$publisher)';
}

/// One thing a publish job sends: the host's [itemId], the item's local
/// [key] and where its bytes come from ([source]).
@immutable
final class PublishItem {
  /// An item; see the fields.
  const PublishItem({
    required this.itemId,
    required this.key,
    required this.source,
    this.fingerprint,
    this.fileName,
  });

  /// The host's id for the item, opaque to the engine and unique within
  /// its job.
  final String itemId;

  /// The item's local key: what a surface shows it by while it uploads.
  final MediaKey key;

  /// Where the item's bytes come from.
  final PublishSource source;

  /// The host's value for the item's content, which the reuse table knows
  /// a source by (for an item of the device's library, its asset id and
  /// modification date); null for the file's path, size and modification
  /// time.
  final String? fingerprint;

  /// The file's name for the remote end, when the host gives one.
  final String? fileName;

  @override
  bool operator ==(Object other) =>
      other is PublishItem &&
      other.itemId == itemId &&
      other.key == key &&
      other.source == source &&
      other.fingerprint == fingerprint &&
      other.fileName == fileName;

  @override
  int get hashCode => Object.hash(itemId, key, source, fingerprint, fileName);

  @override
  String toString() => 'PublishItem($itemId, $source)';
}

/// Where a publish item's bytes come from.
@immutable
sealed class PublishSource {
  const PublishSource();

  /// [input], prepared as [intent] through the facade's
  /// `MediaPreparation` before it uploads. A facade without one refuses
  /// the job.
  const factory PublishSource.prepare(
    PreparationInput input,
    PreparationIntent intent,
  ) = PublishSource$Prepare;

  /// [media], already prepared: it uploads as it is.
  const factory PublishSource.prepared(PreparedMedia media) =
      PublishSource$Prepared;

  /// Nothing to upload: the item's key already has a server identity
  /// (received, or aliased), and the publisher sends it by that key.
  const factory PublishSource.remote() = PublishSource$Remote;
}

/// [PublishSource.prepare].
final class PublishSource$Prepare extends PublishSource {
  /// See [PublishSource.prepare].
  const PublishSource$Prepare(this.input, this.intent);

  /// The file the preparation reads.
  final PreparationInput input;

  /// How it is prepared.
  final PreparationIntent intent;

  @override
  bool operator ==(Object other) =>
      other is PublishSource$Prepare &&
      other.input == input &&
      other.intent == intent;

  @override
  int get hashCode => Object.hash(PublishSource$Prepare, input, intent);

  @override
  String toString() => 'PublishSource.prepare($intent)';
}

/// [PublishSource.prepared].
final class PublishSource$Prepared extends PublishSource {
  /// See [PublishSource.prepared].
  const PublishSource$Prepared(this.media);

  /// The prepared file, with its thumbnail when it has one.
  final PreparedMedia media;

  @override
  bool operator ==(Object other) =>
      other is PublishSource$Prepared && other.media == media;

  @override
  int get hashCode => Object.hash(PublishSource$Prepared, media);

  @override
  String toString() => 'PublishSource.prepared(${media.kind.name})';
}

/// [PublishSource.remote].
final class PublishSource$Remote extends PublishSource {
  /// See [PublishSource.remote].
  const PublishSource$Remote();

  @override
  bool operator ==(Object other) => other is PublishSource$Remote;

  @override
  int get hashCode => (PublishSource$Remote).hashCode;

  @override
  String toString() => 'PublishSource.remote()';
}

/// [PublishRequest] refused: an item needs preparation and the facade was
/// opened without a `MediaPreparation`.
final class PreparationUnavailable implements Exception {
  /// The refusal of item [itemId].
  const PreparationUnavailable(this.itemId);

  /// The first item that needs preparation.
  final String itemId;

  @override
  String toString() =>
      'PreparationUnavailable($itemId): the facade has no MediaPreparation.';
}
