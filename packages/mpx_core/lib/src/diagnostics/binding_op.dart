import 'package:mpx_core/src/diagnostics/mpx_event.dart';

/// The core's own diagnostics operations, category `binding`: a binding
/// between an asset and the transfer that brings its content.
enum BindingOp implements DiagnosticOp {
  /// A download the binding tracks started (debug; `origin`; the key).
  trackedDownload,

  /// A transfer's state mapped onto the binding's (trace; `state`,
  /// `transfer`; the job and the key). Reported by the `TrackedTransfers`
  /// implementation, which knows the job, once per change of a watched
  /// key's value.
  mapped,

  /// A cancel on the binding forwarded to its transfer (info; `direction`;
  /// the job and the key).
  cancelForwarded,

  /// A binding with no transfer behind it (debug; the key).
  untracked;

  @override
  String get category => 'binding';
}
