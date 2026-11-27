import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals, mapEquals, setEquals;
import 'package:meta/meta.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_transfer/src/upload/remote_ref.dart';

/// The host's code that publishes a job once its items are on the remote
/// end: a chat message sent, a post created.
///
/// Registered by id at app start (`Transfers.registerPublisher`), because
/// a closure cannot be journaled: after a restart a job finds its
/// publisher again by that id, and waits until the host registers it.
abstract interface class Publisher {
  /// Publishes [payload], the host's bytes from the request, with [items]:
  /// each item's id to its remote references, in the request's order.
  ///
  /// [idempotencyKey] is the same on every attempt of one job, retries and
  /// restarts included, so the remote end applies the publish once.
  Future<PublishOutcome> publish(
    Uint8List payload,
    Map<String, PublishItemRefs> items,
    String idempotencyKey,
  );
}

/// One item as its publisher receives it: its local [key] and where its
/// upload put it.
@immutable
final class PublishItemRefs {
  /// The references of an item whose local key is [key].
  const PublishItemRefs({required this.key, this.file, this.thumbnail});

  /// The item's local key; for an item sent as remote, the key that
  /// already has a server identity.
  final MediaKey key;

  /// Where the item's file lives; null for an item sent as remote.
  final RemoteRef? file;

  /// Where its thumbnail lives, when the transport took it separately.
  final RemoteRef? thumbnail;

  /// Whether nothing was uploaded for the item: its [key] is on the remote
  /// end already.
  bool get isRemote => file == null;

  @override
  bool operator ==(Object other) =>
      other is PublishItemRefs &&
      other.key == key &&
      other.file == file &&
      other.thumbnail == thumbnail;

  @override
  int get hashCode => Object.hash(key, file, thumbnail);

  @override
  String toString() => 'PublishItemRefs(${isRemote ? 'remote' : 'uploaded'})';
}

/// What a publisher answered.
@immutable
sealed class PublishOutcome {
  const PublishOutcome();

  /// Published: the job completes with [result], the host's bytes; the
  /// remote end's key for each item is in [serverKeys], item id to key.
  ///
  /// Once the completion is journaled, each server key is aliased in the
  /// bytes cache to the bytes its item's local key holds, so content asked
  /// for by the server key is served from what was sent. Never earlier: the
  /// server key exists only once the publisher answers.
  factory PublishOutcome.published({
    Uint8List? result,
    Map<String, MediaKey> serverKeys,
  }) = PublishOutcome$Published;

  /// The remote end wants items [itemIds] again (it lost them, or refused
  /// what the reuse table answered): their reuse entries are dropped, they
  /// upload again and the job publishes again with the same idempotency
  /// key. Honoured once per job; a second one fails the job at the publish
  /// stage. Ids the job has no uploaded file for are ignored.
  factory PublishOutcome.reuploadItems(Iterable<String> itemIds) =
      PublishOutcome$ReuploadItems;

  /// The remote end refused the publish: the job fails at the publish
  /// stage with [reason], a short code of the host's, and [retryable].
  /// A retry of the job calls the publisher again and uploads nothing.
  const factory PublishOutcome.rejected({
    required String reason,
    bool retryable,
  }) = PublishOutcome$Rejected;

  /// The outcome's name, for diagnostics.
  String get name;
}

/// [PublishOutcome.published].
final class PublishOutcome$Published extends PublishOutcome {
  /// See [PublishOutcome.published].
  PublishOutcome$Published({
    Uint8List? result,
    Map<String, MediaKey> serverKeys = const {},
  }) : result = result == null ? null : Uint8List.fromList(result),
       serverKeys = Map.unmodifiable(serverKeys);

  /// The host's answer, opaque to the engine; the job completes with it.
  final Uint8List? result;

  /// The remote end's key of each item, by item id.
  final Map<String, MediaKey> serverKeys;

  @override
  String get name => 'published';

  @override
  bool operator ==(Object other) =>
      other is PublishOutcome$Published &&
      listEquals(other.result, result) &&
      mapEquals(other.serverKeys, serverKeys);

  @override
  int get hashCode => Object.hash(
    Object.hashAll(result ?? []),
    Object.hashAllUnordered(
      serverKeys.entries.map((entry) => Object.hash(entry.key, entry.value)),
    ),
  );

  @override
  String toString() =>
      'PublishOutcome.published(${serverKeys.length} server keys)';
}

/// [PublishOutcome.reuploadItems].
final class PublishOutcome$ReuploadItems extends PublishOutcome {
  /// See [PublishOutcome.reuploadItems].
  PublishOutcome$ReuploadItems(Iterable<String> itemIds)
    : itemIds = Set.unmodifiable(itemIds);

  /// The items to upload again.
  final Set<String> itemIds;

  @override
  String get name => 'reuploadItems';

  @override
  bool operator ==(Object other) =>
      other is PublishOutcome$ReuploadItems &&
      setEquals(other.itemIds, itemIds);

  @override
  int get hashCode => Object.hashAllUnordered(itemIds);

  @override
  String toString() => 'PublishOutcome.reuploadItems(${itemIds.length} items)';
}

/// [PublishOutcome.rejected].
final class PublishOutcome$Rejected extends PublishOutcome {
  /// See [PublishOutcome.rejected].
  const PublishOutcome$Rejected({required this.reason, this.retryable = false});

  /// A short code for why, the host's.
  final String reason;

  /// Whether publishing again may succeed.
  final bool retryable;

  @override
  String get name => 'rejected';

  @override
  bool operator ==(Object other) =>
      other is PublishOutcome$Rejected &&
      other.reason == reason &&
      other.retryable == retryable;

  @override
  int get hashCode => Object.hash(PublishOutcome$Rejected, reason, retryable);

  @override
  String toString() => 'PublishOutcome.rejected($reason, $retryable)';
}
