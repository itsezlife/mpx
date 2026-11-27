import 'package:mpx_core/mpx_core.dart';

/// The diagnostics operations of the OS envelope, category `envelope`, as
/// the engine sees it.
enum EnvelopeOp implements DiagnosticOp {
  /// The engine asked for an envelope over its `system` jobs (debug; `jobs`;
  /// the first job).
  startRequested,

  /// The system ended the envelope; its jobs paused (warning; `jobs`).
  systemEnded,

  /// The engine stopped the envelope (info; `why`: `drained`).
  withdrawn;

  @override
  String get category => 'envelope';
}
