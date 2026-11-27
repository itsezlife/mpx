import 'dart:async';
import 'dart:typed_data';

import 'package:http_bytes_cache/src/http/http_bytes_upload.dart';

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

  /// The body could not be written into its file, or an upload's body
  /// could not be read from its source.
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

/// What an upload's server answered: the status, the headers and the
/// (small) body, read whole.
final class UploadAnswer {
  /// Creates the answer to an upload.
  const UploadAnswer({
    required this.statusCode,
    required this.headers,
    required this.body,
  });

  /// The answer's status.
  final int statusCode;

  /// The answer's headers, names lower case.
  final Map<String, String> headers;

  /// The answer's body.
  final Uint8List body;
}

/// Sends a request whose body streams from an [HttpBytesUploadBody]: on the
/// VM from the transfer worker, on the web through `fetch`.
///
/// Errors are [TransferFailed]; [HttpBytesClient] maps them to its own.
// A seam with two implementers, one per platform, and [TransferWorker]
// extends it: a function type could not be implemented by the worker.
// ignore: one_member_abstracts
abstract interface class UploadSender {
  /// Sends [method] to [url] with [headers] and [body]; completes with the
  /// answer. [onSent] hears the bytes of the body sent so far, growing, the
  /// last report the body's length. [abort] completing aborts it.
  Future<UploadAnswer> upload({
    required String method,
    required Uri url,
    required Map<String, String> headers,
    required HttpBytesUploadBody body,
    required Future<void> abort,
    required void Function(int sent) onSent,
  });
}

/// The calling isolate's side of a transfer worker: GETs that keep their
/// body on the worker, bodies written into files there, and uploads whose
/// body is read from a file there.
///
/// Errors are [TransferFailed]; [HttpBytesClient] maps them to its own.
abstract interface class TransferWorker implements UploadSender {
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
