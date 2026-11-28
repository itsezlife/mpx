import 'package:mpx_core/mpx_core.dart';

/// The diagnostics operations of the reuse table, category `reuse`: a
/// source looked up before it is prepared and uploaded, the transport's
/// judgement of what was stored, and entries stored and dropped.
///
/// No field carries user content: never a fingerprint, a path or a remote
/// reference, only results, ages and reasons; the job, item and media key
/// are the event's correlation ids when the caller has them.
enum ReuseOp implements DiagnosticOp {
  /// A source was looked up (trace; `result`: `hit`, `miss` or
  /// `disabled`).
  lookup,

  /// A stored reference was judged still good, so the source is neither
  /// prepared nor uploaded again (debug; `ageS`, seconds since it was
  /// stored; `judgedBy`: `lifetime` or `validityCall`).
  hit,

  /// The transport judged a stored reference no longer good, and the entry
  /// was dropped (info; `judgedBy`: `lifetime` or `validityCall`). A
  /// validity call that threw adds `callFailed: true` and keeps the entry.
  judgedInvalid,

  /// An uploaded source's references were stored (debug; `expiresInH`,
  /// hours until the host's expiry drops them).
  stored,

  /// An entry was dropped (info; `why`: `reuploadItems`, a publisher asked
  /// for the source again, or `expired`, the host's expiry passed).
  invalidated;

  @override
  String get category => 'reuse';
}
