import 'package:mpx_core/mpx_core.dart';

/// The diagnostics operations of the transfer scheduler, category
/// `scheduler`: transfer jobs entering the engine and moving between
/// states.
///
/// No field carries user content: ids and the host's tag are the event's
/// correlation ids, sizes are byte counts.
enum SchedulerOp implements DiagnosticOp {
  /// A job was accepted, or went back to queued on a retry (debug;
  /// `direction`, `durability`, `priority`; job, key, tag).
  jobQueued,

  /// A job moved its first bytes of an attempt (debug; `waitedMs` since it
  /// was queued; job, tag).
  jobStarted,

  /// A job paused (info; `reason`; job, key, tag).
  paused,

  /// A paused job went back to queued (info; `reason`, the pause reason it
  /// left; job, key, tag).
  resumed,

  /// A job's priority changed (debug; `from`, `to`; job, key).
  priorityChanged,

  /// A job was cancelled and removed (info; `by`; job, key, tag).
  cancelled,

  /// A job's attempt failed (error; `kind`, `retryable`, `done`, `total`
  /// when known; job, key, tag).
  failed,

  /// A job completed (info; `bytes`, `ms` since it was made; job, key, tag).
  completed,

  /// The composition root reported connectivity (info; `online`,
  /// `jobsAffected`, the jobs it resumed).
  connectivityChanged,

  /// A tracked download was asked for (debug; `origin`, `resumeOnStart`,
  /// `existing` when the key already had a job; job, key).
  downloadRequested;

  @override
  String get category => 'scheduler';
}
