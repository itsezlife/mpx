import 'package:mpx_core/mpx_core.dart';

/// The diagnostics operations of an upload's transport, category
/// `transport`: a session opening, its parts going out and coming back,
/// and the upload finishing.
///
/// No field carries user content: indexes, offsets, byte counts, times,
/// HTTP statuses and short error codes; the transport by its id, which
/// names a protocol. Paths, URLs, resume tokens and receipts stay out.
enum TransportOp implements DiagnosticOp {
  /// A session opened (debug; `transport`, the transport's id; `resumed`;
  /// `offset`, the bytes known sent from the start; `size`; job).
  sessionOpened,

  /// A part went out, once per try (trace; `index`, `offset`, `bytes`,
  /// `inFlight`, the bytes outstanding with it; job).
  partSent,

  /// A part was acknowledged (trace; `index`, `ms` since its try went out;
  /// job).
  partAcked,

  /// A try failed and is tried again after a wait (warning; `step`: `open`,
  /// `part` or `finish`; `index` for a part; `attempt`, the try that
  /// failed, from 1; `delayMs`; `status` when the failure was an answer,
  /// else `code`; job).
  partRetry,

  /// A try failed and no try follows, so the upload fails (error; `step`;
  /// `index` for a part; `attempts`; `status` when the failure was an
  /// answer, else `code`; job).
  partGaveUp,

  /// Every part was acknowledged and the remote end completed the upload
  /// (info; `finalSize`, `parts`, `ms` since the session began opening;
  /// job).
  finished;

  @override
  String get category => 'transport';
}
