import 'package:meta/meta.dart';
import 'package:mpx_transfer/src/job/transfer_id.dart';

/// The OS envelope: what the platform offers to keep `system` transfers
/// running while the app is in the background (a user-initiated job or a
/// foreground service on Android, a background or continued-processing task
/// on iOS).
///
/// The engine moves the bytes in process; the envelope only holds the
/// process up and shows the platform's progress UI. Progress is mirrored
/// from the engine and never counted natively. The engine starts an envelope
/// for a set of jobs, updates its progress, and stops it when they drain;
/// the native part reports what the system and the user did to it through
/// [events].
///
/// Engine tests use `FakeTransferEnvelope` from `testing.dart`.
abstract interface class TransferEnvelope {
  /// Starts the envelope over the jobs in [progress]; with one already
  /// started, the next [update] or [stop] refers to it.
  void start(TransferEnvelopeProgress progress);

  /// Mirrors the engine's progress over the jobs in the envelope, which may
  /// have changed since [start].
  void update(TransferEnvelopeProgress progress);

  /// Ends the envelope: its jobs drained or left it.
  void stop();

  /// What the system or the user did to the envelope.
  Stream<TransferEnvelopeEvent> get events;
}

/// The jobs inside an OS envelope and their bytes, summed.
@immutable
final class TransferEnvelopeProgress {
  /// [done] of [total] bytes (null when any job's size is unknown) over
  /// [jobs].
  const TransferEnvelopeProgress({
    required this.jobs,
    required this.done,
    this.total,
  });

  /// The jobs inside the envelope.
  final Set<TransferId> jobs;

  /// Bytes moved over those jobs.
  final int done;

  /// Their sizes summed, or null when any is unknown.
  final int? total;

  @override
  bool operator ==(Object other) =>
      other is TransferEnvelopeProgress &&
      other.done == done &&
      other.total == total &&
      other.jobs.length == jobs.length &&
      other.jobs.containsAll(jobs);

  @override
  int get hashCode => Object.hash(done, total, Object.hashAllUnordered(jobs));

  @override
  String toString() => 'TransferEnvelopeProgress($jobs, $done, $total)';
}

/// What the native part of the envelope reports.
@immutable
sealed class TransferEnvelopeEvent {
  const TransferEnvelopeEvent();

  /// The system ended the envelope (its time ran out, the process was low on
  /// memory, a service hit its time limit). The jobs inside stop; nothing is
  /// deleted.
  const factory TransferEnvelopeEvent.systemEnded() =
      TransferEnvelopeEvent$SystemEnded;

  /// The user cancelled every job in the envelope from the system's UI.
  const factory TransferEnvelopeEvent.userCancelledAll() =
      TransferEnvelopeEvent$UserCancelledAll;

  /// The user tapped the envelope's notification, which showed job [id].
  const factory TransferEnvelopeEvent.notificationTap(TransferId id) =
      TransferEnvelopeEvent$NotificationTap;
}

/// [TransferEnvelopeEvent.systemEnded].
final class TransferEnvelopeEvent$SystemEnded extends TransferEnvelopeEvent {
  /// See [TransferEnvelopeEvent.systemEnded].
  const TransferEnvelopeEvent$SystemEnded();

  @override
  bool operator ==(Object other) => other is TransferEnvelopeEvent$SystemEnded;

  @override
  int get hashCode => (TransferEnvelopeEvent$SystemEnded).hashCode;

  @override
  String toString() => 'TransferEnvelopeEvent.systemEnded()';
}

/// [TransferEnvelopeEvent.userCancelledAll].
final class TransferEnvelopeEvent$UserCancelledAll
    extends TransferEnvelopeEvent {
  /// See [TransferEnvelopeEvent.userCancelledAll].
  const TransferEnvelopeEvent$UserCancelledAll();

  @override
  bool operator ==(Object other) =>
      other is TransferEnvelopeEvent$UserCancelledAll;

  @override
  int get hashCode => (TransferEnvelopeEvent$UserCancelledAll).hashCode;

  @override
  String toString() => 'TransferEnvelopeEvent.userCancelledAll()';
}

/// [TransferEnvelopeEvent.notificationTap].
final class TransferEnvelopeEvent$NotificationTap
    extends TransferEnvelopeEvent {
  /// See [TransferEnvelopeEvent.notificationTap].
  const TransferEnvelopeEvent$NotificationTap(this.id);

  /// The job the notification showed.
  final TransferId id;

  @override
  bool operator ==(Object other) =>
      other is TransferEnvelopeEvent$NotificationTap && other.id == id;

  @override
  int get hashCode => Object.hash(TransferEnvelopeEvent$NotificationTap, id);

  @override
  String toString() => 'TransferEnvelopeEvent.notificationTap($id)';
}
