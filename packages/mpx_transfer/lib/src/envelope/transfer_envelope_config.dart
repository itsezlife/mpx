import 'package:meta/meta.dart';
import 'package:mpx_transfer/src/envelope/transfer_envelope.dart';

/// What the host gives the OS envelope: the text and icon of the
/// platform's progress UI (a notification, the system's progress for a
/// continued-processing task), already localised, and its say over when
/// the envelope starts.
///
/// mpx holds no strings of its own, so without a config the engine starts
/// no envelope: `system` jobs run in process, reported once per run as
/// `envelope` `degraded` (`why: unconfigured`).
@immutable
final class TransferEnvelopeConfig {
  /// A config showing [title] over the envelope's jobs.
  const TransferEnvelopeConfig({
    required this.title,
    this.text,
    this.cancelAllLabel,
    this.progressText,
    this.icon,
    this.startRule,
    this.longJobBytes = defaultLongJobBytes,
    this.submitAt = const TransferEnvelopeSubmitAt.afterDelay(),
  });

  /// The largest job that is not long by default: 10 MiB.
  static const int defaultLongJobBytes = 10 * 1024 * 1024;

  /// The title of the platform's progress UI.
  final String title;

  /// The line under [title]; none when null.
  final String? text;

  /// The label of the action that cancels every job in the envelope, where
  /// the platform shows one (a notification action); the platform's own
  /// label when null.
  final String? cancelAllLabel;

  /// The progress line for [TransferEnvelopeProgress] (for instance "3 of
  /// 5 files"), worked out on the Dart side at each update; the platform's
  /// own bar alone when null.
  final String Function(TransferEnvelopeProgress progress)? progressText;

  /// The platform's name for the icon (an Android drawable resource
  /// name); the app's icon when null. Ignored where the platform draws its
  /// own.
  final String? icon;

  /// When the envelope starts; the platform's rule
  /// ([TransferEnvelope.startRule]) when null.
  final TransferEnvelopeStartRule? startRule;

  /// The size over which a job is long for [TransferEnvelopeStartRule.long]:
  /// a job of more bytes than this, summed over a publish job's uploads,
  /// starts the envelope. A video is long at any size.
  final int longJobBytes;

  /// When a continued-processing task is asked for after the app left the
  /// foreground, where the platform has one.
  final TransferEnvelopeSubmitAt submitAt;
}

/// When the engine starts the OS envelope for a `system` job.
enum TransferEnvelopeStartRule {
  /// Only for a long job: any of its files a video, or more bytes than
  /// [TransferEnvelopeConfig.longJobBytes]. Shorter jobs run in process,
  /// and join an envelope a long job started.
  long,

  /// For every `system` job.
  always,

  /// Never: `system` jobs run in process.
  never,
}

/// When a continued-processing task is submitted after the app left the
/// foreground with `system` jobs still running.
@immutable
sealed class TransferEnvelopeSubmitAt {
  const TransferEnvelopeSubmitAt();

  /// [delay] after the app left the foreground, if `system` jobs remain.
  const factory TransferEnvelopeSubmitAt.afterDelay([Duration delay]) =
      TransferEnvelopeSubmitAt$AfterDelay;

  /// As soon as the app resigns active.
  const factory TransferEnvelopeSubmitAt.onResignActive() =
      TransferEnvelopeSubmitAt$OnResignActive;

  /// The delay of [TransferEnvelopeSubmitAt.afterDelay] by default: 10 s.
  static const Duration defaultDelay = Duration(seconds: 10);

  /// The value's name in diagnostics: `afterDelay` or `onResignActive`.
  String get name;
}

/// [TransferEnvelopeSubmitAt.afterDelay].
final class TransferEnvelopeSubmitAt$AfterDelay
    extends TransferEnvelopeSubmitAt {
  /// See [TransferEnvelopeSubmitAt.afterDelay].
  const TransferEnvelopeSubmitAt$AfterDelay([
    this.delay = TransferEnvelopeSubmitAt.defaultDelay,
  ]);

  /// How long after leaving the foreground.
  final Duration delay;

  @override
  String get name => 'afterDelay';

  @override
  bool operator ==(Object other) =>
      other is TransferEnvelopeSubmitAt$AfterDelay && other.delay == delay;

  @override
  int get hashCode => Object.hash(TransferEnvelopeSubmitAt$AfterDelay, delay);

  @override
  String toString() => 'TransferEnvelopeSubmitAt.afterDelay($delay)';
}

/// [TransferEnvelopeSubmitAt.onResignActive].
final class TransferEnvelopeSubmitAt$OnResignActive
    extends TransferEnvelopeSubmitAt {
  /// See [TransferEnvelopeSubmitAt.onResignActive].
  const TransferEnvelopeSubmitAt$OnResignActive();

  @override
  String get name => 'onResignActive';

  @override
  bool operator ==(Object other) =>
      other is TransferEnvelopeSubmitAt$OnResignActive;

  @override
  int get hashCode => (TransferEnvelopeSubmitAt$OnResignActive).hashCode;

  @override
  String toString() => 'TransferEnvelopeSubmitAt.onResignActive()';
}
