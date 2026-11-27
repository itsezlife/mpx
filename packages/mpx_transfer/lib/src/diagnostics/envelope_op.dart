import 'package:mpx_core/mpx_core.dart';

/// The diagnostics operations of the OS envelope, category `envelope`, as
/// the engine sees it.
enum EnvelopeOp implements DiagnosticOp {
  /// The engine asked for an envelope over its `system` jobs (debug; `jobs`,
  /// `rule`: `long` or `always`; the job that asked).
  startRequested,

  /// The envelope started, or was taken over from an earlier run (info;
  /// `handle`, `kind` when known, `adopted`).
  started,

  /// A job queued without an envelope (debug; `why`: `short`, `never`,
  /// `inProcess`, `platform`; the job).
  notStarted,

  /// The platform refused the envelope (warning; `code`).
  refused,

  /// `system` jobs run in process instead (warning; `from`, `to`, `why`:
  /// `unconfigured`, `refused`).
  degraded,

  /// The system ended the envelope; its jobs paused (warning; `jobs`,
  /// `cause`; the first job).
  systemEnded,

  /// The user cancelled every job in the envelope (info; `jobs`; the first
  /// job).
  userCancelledAll,

  /// The engine stopped the envelope (info; `why`: `drained`).
  withdrawn,

  /// The user tapped the envelope's notification (info; the job it
  /// showed).
  notificationTap;

  @override
  String get category => 'envelope';
}
