import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals, mapEquals;
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
  factory PublishOutcome.published({
    Uint8List? result,
    Map<String, MediaKey> serverKeys,
  }) = PublishOutcome$Published;

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
