import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:meta/meta.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_transfer/src/job/transfer_state.dart';
import 'package:mpx_transfer/src/publish/publish_request.dart';
import 'package:mpx_transfer/src/upload/remote_ref.dart';

/// Why a publish job or one of its items failed: a short code, safe for
/// diagnostics.
///
/// An open set: beside the engine's own codes, named here, a reason is an
/// upload's failure kind ([TransferFailureKind.name]), a preparation's code
/// (`PreparationFailed.code`, which preparers extend) or the reason the
/// publisher gave with a rejection.
extension type const PublishFailureReason(String code) implements String {
  /// An item needs preparing and the facade was built without preparation.
  static const PublishFailureReason noPreparation = PublishFailureReason(
    'noPreparation',
  );

  /// The item's preparation or upload was cancelled under it.
  static const PublishFailureReason cancelled = PublishFailureReason(
    'cancelled',
  );

  /// The preparation threw something other than a preparation failure.
  static const PublishFailureReason unexpected = PublishFailureReason(
    'unexpected',
  );

  /// The job names a transport the engine was not given.
  static const PublishFailureReason unknownTransport = PublishFailureReason(
    'unknownTransport',
  );

  /// Bytes held in memory could not be written to a file to upload.
  static const PublishFailureReason sourceUnwritable = PublishFailureReason(
    'sourceUnwritable',
  );

  /// The prepared thumbnail could not be read.
  static const PublishFailureReason thumbnailUnreadable = PublishFailureReason(
    'thumbnailUnreadable',
  );

  /// The transport refused the upload as described.
  static const PublishFailureReason transport = PublishFailureReason(
    'transport',
  );

  /// The publisher threw instead of answering an outcome.
  static const PublishFailureReason publisherError = PublishFailureReason(
    'publisherError',
  );

  /// The publisher asked for items again after the one resend it gets.
  static const PublishFailureReason reuploadRefused = PublishFailureReason(
    'reuploadRefused',
  );
}

/// The step of a publish job a failure stopped.
enum PublishStage {
  /// Preparing an item (compression, still encoding).
  prepare,

  /// Uploading an item's file or thumbnail.
  upload,

  /// The publisher's call.
  publish,
}

/// Where a publish job is.
///
/// - [preparing] while any item still prepares, [uploading] while any
///   still uploads, [publishing] once everything is uploaded, while the
///   publisher's call is under way or the job waits for the jobs ahead of
///   it in its ordering group;
/// - [awaitingPublisher] when everything is uploaded and no publisher is
///   registered under the job's id;
/// - [awaitingOwner] when every item was removed and the owner decides;
/// - [paused] while an upload of the job is paused, with its reason;
/// - [failed] with the step that failed, and [completed] with the
///   publisher's result.
@immutable
sealed class PublishJobState {
  const PublishJobState();

  /// An item still prepares.
  const factory PublishJobState.preparing() = PublishJobState$Preparing;

  /// An item still uploads.
  const factory PublishJobState.uploading() = PublishJobState$Uploading;

  /// The publisher's call is under way.
  const factory PublishJobState.publishing() = PublishJobState$Publishing;

  /// Waiting for the publisher to be registered.
  const factory PublishJobState.awaitingPublisher() =
      PublishJobState$AwaitingPublisher;

  /// Every item was removed; the owner decides.
  const factory PublishJobState.awaitingOwner() = PublishJobState$AwaitingOwner;

  /// An upload of the job is paused for [reason].
  const factory PublishJobState.paused(PauseReason reason) =
      PublishJobState$Paused;

  /// [stage] failed for [reason], a short code; [retryable] when a retry
  /// may succeed.
  const factory PublishJobState.failed({
    required PublishStage stage,
    required PublishFailureReason reason,
    required bool retryable,
  }) = PublishJobState$Failed;

  /// The job is done: the publisher answered [result] (null for a job with
  /// no publisher, which completes once its items are uploaded).
  const factory PublishJobState.completed(Uint8List? result) =
      PublishJobState$Completed;

  /// The state's name, for diagnostics.
  String get name;
}

/// [PublishJobState.preparing].
final class PublishJobState$Preparing extends PublishJobState {
  /// See [PublishJobState.preparing].
  const PublishJobState$Preparing();

  @override
  String get name => 'preparing';

  @override
  String toString() => 'PublishJobState.preparing';
}

/// [PublishJobState.uploading].
final class PublishJobState$Uploading extends PublishJobState {
  /// See [PublishJobState.uploading].
  const PublishJobState$Uploading();

  @override
  String get name => 'uploading';

  @override
  String toString() => 'PublishJobState.uploading';
}

/// [PublishJobState.publishing].
final class PublishJobState$Publishing extends PublishJobState {
  /// See [PublishJobState.publishing].
  const PublishJobState$Publishing();

  @override
  String get name => 'publishing';

  @override
  String toString() => 'PublishJobState.publishing';
}

/// [PublishJobState.awaitingPublisher].
final class PublishJobState$AwaitingPublisher extends PublishJobState {
  /// See [PublishJobState.awaitingPublisher].
  const PublishJobState$AwaitingPublisher();

  @override
  String get name => 'awaitingPublisher';

  @override
  String toString() => 'PublishJobState.awaitingPublisher';
}

/// [PublishJobState.awaitingOwner]: the job's last item was removed, and
/// it publishes nothing until its owner commits it (publishing what is
/// left: the payload alone, or new items of a held job) or cancels it.
final class PublishJobState$AwaitingOwner extends PublishJobState {
  /// See [PublishJobState.awaitingOwner].
  const PublishJobState$AwaitingOwner();

  @override
  String get name => 'awaitingOwner';

  @override
  String toString() => 'PublishJobState.awaitingOwner';
}

/// [PublishJobState.paused].
final class PublishJobState$Paused extends PublishJobState {
  /// See [PublishJobState.paused].
  const PublishJobState$Paused(this.reason);

  /// Why the job's upload is paused.
  final PauseReason reason;

  @override
  String get name => 'paused';

  @override
  bool operator ==(Object other) =>
      other is PublishJobState$Paused && other.reason == reason;

  @override
  int get hashCode => Object.hash(PublishJobState$Paused, reason);

  @override
  String toString() => 'PublishJobState.paused(${reason.name})';
}

/// [PublishJobState.failed].
final class PublishJobState$Failed extends PublishJobState {
  /// See [PublishJobState.failed].
  const PublishJobState$Failed({
    required this.stage,
    required this.reason,
    required this.retryable,
  });

  /// The step that failed.
  final PublishStage stage;

  /// A short code for why, safe for diagnostics.
  final PublishFailureReason reason;

  /// Whether a retry may succeed.
  final bool retryable;

  @override
  String get name => 'failed';

  @override
  bool operator ==(Object other) =>
      other is PublishJobState$Failed &&
      other.stage == stage &&
      other.reason == reason &&
      other.retryable == retryable;

  @override
  int get hashCode =>
      Object.hash(PublishJobState$Failed, stage, reason, retryable);

  @override
  String toString() =>
      'PublishJobState.failed(${stage.name}, $reason, $retryable)';
}

/// [PublishJobState.completed].
final class PublishJobState$Completed extends PublishJobState {
  /// See [PublishJobState.completed].
  const PublishJobState$Completed(this.result);

  /// The publisher's answer, opaque to the engine; null for a job with no
  /// publisher.
  final Uint8List? result;

  @override
  String get name => 'completed';

  @override
  bool operator ==(Object other) =>
      other is PublishJobState$Completed && listEquals(other.result, result);

  @override
  int get hashCode =>
      Object.hash(PublishJobState$Completed, Object.hashAll(result ?? []));

  @override
  String toString() => 'PublishJobState.completed(${result?.length} B)';
}

/// Where one item of a publish job is.
@immutable
sealed class PublishItemState {
  const PublishItemState();

  /// Not started: looked up, or waiting for its preparation to start.
  const factory PublishItemState.waiting() = PublishItemState$Waiting;

  /// Removed from its job.
  const factory PublishItemState.removed() = PublishItemState$Removed;

  /// Preparing, [fraction] done (0..1).
  const factory PublishItemState.preparing(double fraction) =
      PublishItemState$Preparing;

  /// Uploading: [sent] of [total] bytes, the file and its thumbnail
  /// together; [estimated] while a total is still a guess.
  const factory PublishItemState.uploading({
    required int sent,
    int? total,
    bool estimated,
  }) = PublishItemState$Uploading;

  /// On the remote end: [file] and [thumbnail] are where the upload
  /// answered they live; both null for an item sent as remote.
  const factory PublishItemState.uploaded({
    RemoteRef? file,
    RemoteRef? thumbnail,
  }) = PublishItemState$Uploaded;

  /// [stage] failed for [reason], a short code; [retryable] when a retry
  /// may succeed.
  const factory PublishItemState.failed({
    required PublishStage stage,
    required PublishFailureReason reason,
    required bool retryable,
  }) = PublishItemState$Failed;

  /// The state's name, for diagnostics.
  String get name;
}

/// [PublishItemState.waiting].
final class PublishItemState$Waiting extends PublishItemState {
  /// See [PublishItemState.waiting].
  const PublishItemState$Waiting();

  @override
  String get name => 'waiting';

  @override
  String toString() => 'PublishItemState.waiting';
}

/// [PublishItemState.preparing].
final class PublishItemState$Preparing extends PublishItemState {
  /// See [PublishItemState.preparing].
  const PublishItemState$Preparing(this.fraction);

  /// How much of the preparation is done, 0..1.
  final double fraction;

  @override
  String get name => 'preparing';

  @override
  bool operator ==(Object other) =>
      other is PublishItemState$Preparing && other.fraction == fraction;

  @override
  int get hashCode => Object.hash(PublishItemState$Preparing, fraction);

  @override
  String toString() => 'PublishItemState.preparing($fraction)';
}

/// [PublishItemState.uploading].
final class PublishItemState$Uploading extends PublishItemState {
  /// See [PublishItemState.uploading].
  const PublishItemState$Uploading({
    required this.sent,
    this.total,
    this.estimated = false,
  });

  /// The bytes sent so far.
  final int sent;

  /// The bytes to send; null while unknown.
  final int? total;

  /// Whether [total] is still a guess.
  final bool estimated;

  @override
  String get name => 'uploading';

  @override
  bool operator ==(Object other) =>
      other is PublishItemState$Uploading &&
      other.sent == sent &&
      other.total == total &&
      other.estimated == estimated;

  @override
  int get hashCode =>
      Object.hash(PublishItemState$Uploading, sent, total, estimated);

  @override
  String toString() => 'PublishItemState.uploading($sent, $total)';
}

/// [PublishItemState.uploaded].
final class PublishItemState$Uploaded extends PublishItemState {
  /// See [PublishItemState.uploaded].
  const PublishItemState$Uploaded({this.file, this.thumbnail});

  /// Where the item's file lives; null for an item sent as remote.
  final RemoteRef? file;

  /// Where its thumbnail lives, when the transport took it separately.
  final RemoteRef? thumbnail;

  @override
  String get name => 'uploaded';

  @override
  bool operator ==(Object other) =>
      other is PublishItemState$Uploaded &&
      other.file == file &&
      other.thumbnail == thumbnail;

  @override
  int get hashCode => Object.hash(PublishItemState$Uploaded, file, thumbnail);

  @override
  String toString() => 'PublishItemState.uploaded';
}

/// [PublishItemState.failed].
final class PublishItemState$Failed extends PublishItemState {
  /// See [PublishItemState.failed].
  const PublishItemState$Failed({
    required this.stage,
    required this.reason,
    required this.retryable,
  });

  /// The step that failed.
  final PublishStage stage;

  /// A short code for why, safe for diagnostics.
  final PublishFailureReason reason;

  /// Whether a retry may succeed.
  final bool retryable;

  @override
  String get name => 'failed';

  @override
  bool operator ==(Object other) =>
      other is PublishItemState$Failed &&
      other.stage == stage &&
      other.reason == reason &&
      other.retryable == retryable;

  @override
  int get hashCode =>
      Object.hash(PublishItemState$Failed, stage, reason, retryable);

  @override
  String toString() =>
      'PublishItemState.failed(${stage.name}, $reason, $retryable)';
}

/// [PublishItemState.removed]: the item left its job. A job's snapshot no
/// longer lists it; `PublishJob.watchItem` gives this state last.
final class PublishItemState$Removed extends PublishItemState {
  /// See [PublishItemState.removed].
  const PublishItemState$Removed();

  @override
  String get name => 'removed';

  @override
  String toString() => 'PublishItemState.removed';
}

/// One item of a publish job as a query sees it.
@immutable
final class PublishItemSnapshot {
  /// A snapshot of item [itemId].
  const PublishItemSnapshot({
    required this.itemId,
    required this.key,
    required this.state,
    this.progress = 0,
  });

  /// The host's id for the item.
  final String itemId;

  /// The item's local key, so a surface can preview it.
  final MediaKey key;

  /// Where the item is.
  final PublishItemState state;

  /// How much of the item is done, 0..1, its preparation and upload
  /// weighted as `PublishProgressWeights` says; never lower than in an
  /// earlier snapshot of this run.
  final double progress;

  @override
  bool operator ==(Object other) =>
      other is PublishItemSnapshot &&
      other.itemId == itemId &&
      other.key == key &&
      other.state == state &&
      other.progress == progress;

  @override
  int get hashCode => Object.hash(itemId, key, state, progress);

  @override
  String toString() => 'PublishItemSnapshot($itemId, $state, $progress)';
}

/// One publish job as a query sees it: a snapshot, never updated in place.
@immutable
final class PublishJobSnapshot {
  /// A snapshot of job [id].
  PublishJobSnapshot({
    required this.id,
    required this.state,
    required List<PublishItemSnapshot> items,
    required this.createdAt,
    this.tag,
    this.publisher,
    this.aliasesApplied = false,
    this.progress = 0,
    this.held = false,
  }) : items = List.unmodifiable(items);

  /// The job's identity.
  final PublishJobId id;

  /// Where the job is.
  final PublishJobState state;

  /// Its items, in the order the request gave them.
  final List<PublishItemSnapshot> items;

  /// The host's tag, as given.
  final String? tag;

  /// The id of the job's publisher; null for an upload with none.
  final String? publisher;

  /// When the job was made.
  final DateTime createdAt;

  /// Whether the job completed and every server key its publisher gave is
  /// aliased to its item's local key in the bytes cache: from then on the
  /// content answers by its server key, and an item's upload has nothing
  /// left to show. False while the job runs, and between its completion
  /// and the last alias.
  final bool aliasesApplied;

  /// How much of the job is done, 0..1: its items by their bytes, then the
  /// publisher's call (`PublishProgressWeights`). Never lower than in an
  /// earlier snapshot, a restart included; 1 once [state] is completed.
  final double progress;

  /// Whether the job was made with `hold` and is not committed yet: it
  /// prepares and uploads, but publishes only once the host commits it.
  /// [state] goes on reading its items meanwhile (`uploading` once every
  /// item is uploaded).
  final bool held;

  /// The item [itemId], or null when the job has none of that id.
  PublishItemSnapshot? item(String itemId) {
    for (final item in items) {
      if (item.itemId == itemId) return item;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is PublishJobSnapshot &&
      other.id == id &&
      other.state == state &&
      listEquals(other.items, items) &&
      other.tag == tag &&
      other.publisher == publisher &&
      other.createdAt == createdAt &&
      other.aliasesApplied == aliasesApplied &&
      other.progress == progress &&
      other.held == held;

  @override
  int get hashCode => Object.hash(
    id,
    state,
    Object.hashAll(items),
    tag,
    publisher,
    createdAt,
    aliasesApplied,
    progress,
    held,
  );

  @override
  String toString() =>
      'PublishJobSnapshot($id, $state, ${items.length} items, $progress)';
}

/// Which publish jobs `Transfers.watchJobs` gives: those that pass every
/// part given.
@immutable
final class PublishJobFilter {
  /// A filter; with nothing given, every job.
  const PublishJobFilter({
    this.tag,
    this.tagPrefix,
    this.publisher,
    this.state,
  });

  /// Only jobs carrying exactly this tag.
  final String? tag;

  /// Only jobs whose tag starts with this, such as every job of one
  /// conversation when the host's tags start with its id.
  final String? tagPrefix;

  /// Only jobs of this publisher id.
  final String? publisher;

  /// Only jobs whose state passes this test, such as
  /// `(state) => state is PublishJobState$Failed`.
  final bool Function(PublishJobState state)? state;

  /// Whether [job] passes every part given.
  bool matches(PublishJobSnapshot job) =>
      (tag == null || job.tag == tag) &&
      (tagPrefix == null || (job.tag?.startsWith(tagPrefix!) ?? false)) &&
      (publisher == null || job.publisher == publisher) &&
      (state?.call(job.state) ?? true);
}
