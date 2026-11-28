import 'package:meta/meta.dart';
import 'package:mpx_transfer/src/envelope/transfer_envelope_config.dart';
import 'package:mpx_transfer/src/job/transfer_id.dart';

/// The OS envelope: what the platform offers to keep `system` transfers
/// running while the app is in the background (a user-initiated job or a
/// foreground service on Android, a background or continued-processing task
/// on iOS).
///
/// The engine moves the bytes in process; the envelope only holds the
/// process up and shows the platform's progress UI. Progress is mirrored
/// from the engine and never counted natively. The engine keeps at most one
/// envelope: it starts one over its `system` jobs when [startRule] (or the
/// host's [TransferEnvelopeConfig.startRule]) says so, updates its
/// progress, and stops it when they drain; the native part reports what the
/// system and the user did to it through [events].
///
/// The handle a start answers is journaled with each job inside, so after
/// the process ended the next engine matches the envelopes the native part
/// still holds ([live]) to its jobs.
///
/// Engine tests use `FakeTransferEnvelope` from `testing.dart`.
abstract interface class TransferEnvelope {
  /// When this platform's envelope starts unless the host's config says
  /// otherwise: [TransferEnvelopeStartRule.long] where it must start while
  /// the app is visible and shows a notification for each,
  /// [TransferEnvelopeStartRule.always] where the native part holds it
  /// until the app leaves the foreground.
  TransferEnvelopeStartRule get startRule;

  /// The handles of the envelopes the native part still holds from an
  /// earlier run of the process; read once, at the engine's start.
  Future<Set<String>> live();

  /// Starts the envelope over the jobs in [progress], showing [config].
  ///
  /// Answers [TransferEnvelopeStart.started] with the envelope's handle, or
  /// [TransferEnvelopeStart.refused] when the platform would not start it
  /// (a missing permission, the app not visible, a scheduler refusal): the
  /// native part catches the refusal, and the jobs then run in process.
  /// [update] and [stop] may come before the answer; they refer to this
  /// envelope.
  Future<TransferEnvelopeStart> start(
    TransferEnvelopeProgress progress,
    TransferEnvelopeConfig config,
  );

  /// Takes over the envelope [handle] that [live] reported, now over the
  /// jobs in [progress], showing [config].
  void adopt(
    String handle,
    TransferEnvelopeProgress progress,
    TransferEnvelopeConfig config,
  );

  /// Mirrors the engine's progress over the jobs in the envelope, which may
  /// have changed since [start].
  void update(TransferEnvelopeProgress progress);

  /// Ends the envelope: its jobs drained or left it. With no envelope
  /// started, ends any the native part still holds.
  void stop();

  /// What the system or the user did to the envelope.
  Stream<TransferEnvelopeEvent> get events;
}

/// The kinds of envelope the platforms offer.
enum TransferEnvelopeKind {
  /// A user-initiated data transfer job (Android 14 and later).
  uidt,

  /// A data-sync foreground service (Android before 14).
  dataSync,

  /// A short background task (iOS).
  bgTask,

  /// A continued-processing task with the system's progress UI (iOS 26 and
  /// later).
  continuedProcessing,
}

/// What a [TransferEnvelope.start] answered.
@immutable
sealed class TransferEnvelopeStart {
  const TransferEnvelopeStart();

  /// The envelope started (or is armed, to start when the app leaves the
  /// foreground) under [handle]; [kind] is what holds the process now,
  /// null while nothing does yet.
  const factory TransferEnvelopeStart.started(
    String handle, {
    TransferEnvelopeKind? kind,
  }) = TransferEnvelopeStart$Started;

  /// The platform refused the envelope; [code] says why in a few words
  /// (`securityException`, `schedulerRefused`, `notVisible`), with no user
  /// content.
  const factory TransferEnvelopeStart.refused(String code) =
      TransferEnvelopeStart$Refused;
}

/// [TransferEnvelopeStart.started].
final class TransferEnvelopeStart$Started extends TransferEnvelopeStart {
  /// See [TransferEnvelopeStart.started].
  const TransferEnvelopeStart$Started(this.handle, {this.kind});

  /// The envelope's handle, unique on the device.
  final String handle;

  /// What holds the process now; null while nothing does yet.
  final TransferEnvelopeKind? kind;

  @override
  bool operator ==(Object other) =>
      other is TransferEnvelopeStart$Started &&
      other.handle == handle &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(TransferEnvelopeStart$Started, handle, kind);

  @override
  String toString() => 'TransferEnvelopeStart.started($handle, $kind)';
}

/// [TransferEnvelopeStart.refused].
final class TransferEnvelopeStart$Refused extends TransferEnvelopeStart {
  /// See [TransferEnvelopeStart.refused].
  const TransferEnvelopeStart$Refused(this.code);

  /// Why, in a few words.
  final String code;

  @override
  bool operator ==(Object other) =>
      other is TransferEnvelopeStart$Refused && other.code == code;

  @override
  int get hashCode => Object.hash(TransferEnvelopeStart$Refused, code);

  @override
  String toString() => 'TransferEnvelopeStart.refused($code)';
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

/// Why the system ended an envelope.
enum TransferEnvelopeEndCause {
  /// Its time ran out.
  expiry,

  /// The process was low on memory.
  lowMemory,

  /// A service or job hit the platform's time limit.
  timeLimit,

  /// The system stopped it for another reason (a quota, a constraint no
  /// longer met).
  stop,

  /// A debug build asked for it (`Transfers.debugSimulateSystemInterruption`).
  simulated,
}

/// What the native part of the envelope reports.
@immutable
sealed class TransferEnvelopeEvent {
  const TransferEnvelopeEvent();

  /// The system ended the envelope, for [cause]. The jobs inside stop;
  /// nothing is deleted.
  const factory TransferEnvelopeEvent.systemEnded({
    TransferEnvelopeEndCause cause,
  }) = TransferEnvelopeEvent$SystemEnded;

  /// The user cancelled every job in the envelope from the system's UI.
  const factory TransferEnvelopeEvent.userCancelledAll() =
      TransferEnvelopeEvent$UserCancelledAll;

  /// The user tapped the envelope's notification, which showed job [id].
  const factory TransferEnvelopeEvent.notificationTap(TransferId id) =
      TransferEnvelopeEvent$NotificationTap;

  /// What holds the process changed to [kind] (null: nothing does now),
  /// and a continued-processing task is due to be submitted at
  /// [submitDueAt] (null: none is waiting).
  const factory TransferEnvelopeEvent.changed({
    TransferEnvelopeKind? kind,
    DateTime? submitDueAt,
  }) = TransferEnvelopeEvent$Changed;
}

/// [TransferEnvelopeEvent.systemEnded].
final class TransferEnvelopeEvent$SystemEnded extends TransferEnvelopeEvent {
  /// See [TransferEnvelopeEvent.systemEnded].
  const TransferEnvelopeEvent$SystemEnded({
    this.cause = TransferEnvelopeEndCause.stop,
  });

  /// Why the system ended it.
  final TransferEnvelopeEndCause cause;

  @override
  bool operator ==(Object other) =>
      other is TransferEnvelopeEvent$SystemEnded && other.cause == cause;

  @override
  int get hashCode => Object.hash(TransferEnvelopeEvent$SystemEnded, cause);

  @override
  String toString() => 'TransferEnvelopeEvent.systemEnded(${cause.name})';
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

/// [TransferEnvelopeEvent.changed].
final class TransferEnvelopeEvent$Changed extends TransferEnvelopeEvent {
  /// See [TransferEnvelopeEvent.changed].
  const TransferEnvelopeEvent$Changed({this.kind, this.submitDueAt});

  /// What holds the process now; null when nothing does.
  final TransferEnvelopeKind? kind;

  /// When a continued-processing task is due to be submitted; null when
  /// none is waiting.
  final DateTime? submitDueAt;

  @override
  bool operator ==(Object other) =>
      other is TransferEnvelopeEvent$Changed &&
      other.kind == kind &&
      other.submitDueAt == submitDueAt;

  @override
  int get hashCode =>
      Object.hash(TransferEnvelopeEvent$Changed, kind, submitDueAt);

  @override
  String toString() => 'TransferEnvelopeEvent.changed($kind, $submitDueAt)';
}
