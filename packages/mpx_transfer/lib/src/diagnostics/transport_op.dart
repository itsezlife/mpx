import 'package:mpx_core/mpx_core.dart';

/// The diagnostics operations of an upload's transport, category
/// `transport`: whether an interrupted upload continues, a session opening, its parts going out and coming back,
/// and the upload finishing.
///
/// No field carries user content: indexes, offsets, byte counts, times,
/// HTTP statuses and short error codes; the transport by its id, which
/// names a protocol. Paths, URLs, resume tokens and receipts stay out.
enum TransportOp implements DiagnosticOp {
  /// A run of an upload that ran before began, and the engine judged
  /// whether it continues (info; `outcome`: `resumed`, `sourceChanged`,
  /// `windowExpired`, `noResume` or `sourceLost`; `offset`, the bytes the
  /// upload continues after, 0 when it starts from zero; job).
  resumeDecision,

  /// A session opened (debug; `transport`, the transport's id; `resumed`;
  /// `offset`, the bytes known sent from the start; `size`; job).
  sessionOpened,

  /// A part went out, once per try (trace; `index`, `offset`, `bytes`;
  /// `inFlight`, the bytes of the parts started and not yet acknowledged,
  /// this one with them, against the transport's budget; job).
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
  finished,

  /// A publish job item's thumbnail goes as an upload of its own, because
  /// the transport takes thumbnails separately (debug; `bytes`; the
  /// thumbnail's upload as job, item).
  thumbnailUpload;

  @override
  String get category => 'transport';
}
