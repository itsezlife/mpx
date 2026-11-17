import 'dart:async';

/// What a transfer worker answered to a GET: the head, the body held on
/// the worker under [id].
final class TransferHead {
  /// Creates the head of transfer [id].
  const TransferHead({
    required this.id,
    required this.statusCode,
    required this.headers,
    required this.contentLength,
  });

  /// The worker's name for the transfer.
  final int id;

  /// The answer's status.
  final int statusCode;

  /// The answer's headers, names lower case.
  final Map<String, String> headers;

  /// The declared length, or null.
  final int? contentLength;
}

/// Why a transfer ended without its body, as the worker saw it.
enum TransferFailure {
  /// The socket failed, or the request could not be sent.
  network,

  /// The body went longer than the receive timeout without a byte.
  timeout,

  /// The body could not be written into its file.
  io,

  /// The transfer was aborted.
  cancelled,
}

/// A transfer that ended without its body.
final class TransferFailed implements Exception {
  /// Creates the failure of class [kind] explained by [message].
  const TransferFailed(this.kind, this.message);

  /// Why.
  final TransferFailure kind;

  /// What went wrong, for logs.
  final String message;

  @override
  String toString() => 'TransferFailed(${kind.name}): $message';
}

/// The calling isolate's side of a transfer worker: GETs that keep their
/// body on the worker, and bodies written into files there.
///
/// Errors are [TransferFailed]; [HttpBytesClient] maps them to its own.
abstract interface class TransferWorker {
  /// Sends a GET of [url] with [headers]; completes with the head. [abort]
  /// completing aborts it, before or after the head.
  Future<TransferHead> get(
    Uri url,
    Map<String, String> headers, {
    required Future<void> abort,
  });

  /// Writes the body of [head] into [path] from [offset], reporting each
  /// span written to [onLanded] in order, awaiting each report.
  Future<void> write(
    TransferHead head,
    String path,
    int offset,
    FutureOr<void> Function(int start, int end) onLanded,
  );

  /// Drops the body of [head].
  void discard(TransferHead head);

  /// Ends the worker; transfers under way fail as cancelled.
  void close();
}
