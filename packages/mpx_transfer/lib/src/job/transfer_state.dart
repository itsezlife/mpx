import 'package:meta/meta.dart';

/// Where a transfer job is: accepted, moving bytes, stopped with its parts
/// kept, failed on its last attempt, or done.
///
/// There is no cancelled state: a cancel removes the job, so a query never
/// sees one. Each variant carries only what is meaningful in it; read the
/// bytes moved through [done] and the size through [total] when the variant
/// does not matter.
@immutable
sealed class TransferState {
  const TransferState();

  /// Accepted, no byte moved yet in this attempt. [total] is the size when
  /// known.
  const factory TransferState.queued({int? total}) = TransferState$Queued;

  /// Bytes are moving: [done] of [total] (null when unknown). [estimated]
  /// is set while [total] is an estimate, as for a source still growing.
  const factory TransferState.running({
    required int done,
    int? total,
    bool estimated,
  }) = TransferState$Running;

  /// Stopped after [done] bytes, with the parts already moved kept, for
  /// [reason].
  const factory TransferState.paused({
    required PauseReason reason,
    int done,
    int? total,
  }) = TransferState$Paused;

  /// The last attempt failed after [done] bytes. [retryable] tells whether
  /// a retry may succeed.
  const factory TransferState.failed({
    required TransferFailureKind kind,
    required bool retryable,
    int done,
    int? total,
  }) = TransferState$Failed;

  /// Done, with what the transfer produced.
  const factory TransferState.completed(TransferResult result) =
      TransferState$Completed;

  /// Bytes moved so far; 0 where the state has none.
  int get done => 0;

  /// The size in bytes, or null when unknown.
  int? get total => null;

  /// Whether the job is waiting for or moving bytes: queued or running.
  bool get isActive => false;
}

/// [TransferState.queued].
final class TransferState$Queued extends TransferState {
  /// See [TransferState.queued].
  const TransferState$Queued({this.total});

  @override
  final int? total;

  @override
  bool get isActive => true;

  @override
  bool operator ==(Object other) =>
      other is TransferState$Queued && other.total == total;

  @override
  int get hashCode => Object.hash(TransferState$Queued, total);

  @override
  String toString() => 'TransferState.queued($total)';
}

/// [TransferState.running].
final class TransferState$Running extends TransferState {
  /// See [TransferState.running].
  const TransferState$Running({
    required this.done,
    this.total,
    this.estimated = false,
  });

  @override
  final int done;

  @override
  final int? total;

  /// Whether [total] is an estimate.
  final bool estimated;

  @override
  bool get isActive => true;

  @override
  bool operator ==(Object other) =>
      other is TransferState$Running &&
      other.done == done &&
      other.total == total &&
      other.estimated == estimated;

  @override
  int get hashCode =>
      Object.hash(TransferState$Running, done, total, estimated);

  @override
  String toString() =>
      'TransferState.running($done, $total'
      '${estimated ? ', estimated' : ''})';
}

/// [TransferState.paused].
final class TransferState$Paused extends TransferState {
  /// See [TransferState.paused].
  const TransferState$Paused({required this.reason, this.done = 0, this.total});

  /// Why the job stopped, and so what starts it again.
  final PauseReason reason;

  @override
  final int done;

  @override
  final int? total;

  @override
  bool operator ==(Object other) =>
      other is TransferState$Paused &&
      other.reason == reason &&
      other.done == done &&
      other.total == total;

  @override
  int get hashCode => Object.hash(TransferState$Paused, reason, done, total);

  @override
  String toString() => 'TransferState.paused(${reason.name}, $done, $total)';
}

/// [TransferState.failed].
final class TransferState$Failed extends TransferState {
  /// See [TransferState.failed].
  const TransferState$Failed({
    required this.kind,
    required this.retryable,
    this.done = 0,
    this.total,
  });

  /// What failed.
  final TransferFailureKind kind;

  /// Whether a retry may succeed.
  final bool retryable;

  @override
  final int done;

  @override
  final int? total;

  @override
  bool operator ==(Object other) =>
      other is TransferState$Failed &&
      other.kind == kind &&
      other.retryable == retryable &&
      other.done == done &&
      other.total == total;

  @override
  int get hashCode =>
      Object.hash(TransferState$Failed, kind, retryable, done, total);

  @override
  String toString() =>
      'TransferState.failed(${kind.name}, $retryable, $done, $total)';
}

/// [TransferState.completed].
final class TransferState$Completed extends TransferState {
  /// See [TransferState.completed].
  const TransferState$Completed(this.result);

  /// What the transfer produced.
  final TransferResult result;

  @override
  bool operator ==(Object other) =>
      other is TransferState$Completed && other.result == result;

  @override
  int get hashCode => Object.hash(TransferState$Completed, result);

  @override
  String toString() => 'TransferState.completed($result)';
}

/// Why a transfer job is paused: a closed set, each reason with the one
/// trigger that enters it and the one that leaves it.
enum PauseReason {
  /// The user paused the job. Left by `Transfers.resume`.
  user,

  /// The system ended the OS envelope the job ran in. Left when the app is
  /// in the foreground again.
  systemInterrupted,

  /// The transfer failed on the network while the device is offline
  /// (`Transfers.connectivityChanged(online: false)`). Left when
  /// connectivity comes back.
  awaitingNetwork,

  /// A download found at start that does not resume by itself (it was not
  /// started by the user). Left when something shows its content again, or
  /// by `Transfers.resume`.
  awaitingResume,
}

/// What made a transfer job fail.
enum TransferFailureKind {
  /// The network failed while the device was online, or a retry budget ran
  /// out on it.
  network,

  /// The remote end refused the transfer.
  server,

  /// Something on the device failed: storage, the file system.
  local,

  /// The upload's source did not survive (on the web, a file that a reload
  /// could not find again). The owner may ask the user for it again.
  sourceLost,
}

/// What a completed transfer produced: for an upload the transport's remote
/// reference, for a download the local file or a lease on the cached bytes.
///
/// The engine stores and hands it back but never reads it; the kinds that
/// implement it come with the uploads and downloads that produce them.
/// Implementations are values: equal when they name the same result.
abstract interface class TransferResult {}
