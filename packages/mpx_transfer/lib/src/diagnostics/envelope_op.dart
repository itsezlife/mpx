import 'package:mpx_core/mpx_core.dart';

/// The diagnostics operations of the OS envelope, category `envelope`, as
/// the engine sees it.
enum EnvelopeOp implements DiagnosticOp {
  /// The engine asked for an envelope over its `system` jobs (debug; `jobs`,
  /// `rule`: `long` or `always`; the job that asked).
  startRequested,

  /// The envelope started, or was taken over from an earlier run (info;
  /// `handle`, `kind` when known, `adopted`); on iOS also each time a
  /// background task or a continued-processing task begins to hold the
  /// process (`kind`, `handle`).
  started,

  /// A job queued without an envelope (debug; `why`: `short`, `never`,
  /// `inProcess`, `platform`; the job).
  notStarted,

  /// The platform refused the envelope (warning; `code`, and `kind` for a
  /// refused background or continued-processing task).
  refused,

  /// `system` jobs run in process instead, or under a lesser envelope
  /// (warning; `from`, `to`, `why`: `unconfigured`, `refused`,
  /// `submitFailed`).
  degraded,

  /// The system ended the envelope; its jobs paused (warning; `jobs`,
  /// `cause`; the first job).
  systemEnded,

  /// The user cancelled every job in the envelope (info; `jobs`; the first
  /// job).
  userCancelledAll,

  /// The engine stopped the envelope, or the app returned to the
  /// foreground and what held the process let go (info; `why`: `drained`,
  /// `foreground`; `kind` for the latter).
  withdrawn,

  /// The user tapped the envelope's notification (info; the job it
  /// showed).
  notificationTap,

  /// The native part showed new progress in the platform's UI (trace;
  /// `jobs`, `fraction` when the size is known; the job shown).
  progressPushed,

  /// The records the native part kept while Dart was not running were
  /// reported, each with its own time and `native: true` (info; `records`,
  /// `oldestAgeS`).
  nativeMerged;

  @override
  String get category => 'envelope';
}
