import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http_bytes_cache/src/http/http_bytes_client.dart';
import 'package:meta/meta.dart';

/// Builds the `http.Client` a transfer worker sends with, on the worker's
/// isolate: a top-level or static function, or a closure that captures only
/// what can cross isolates.
typedef HttpBytesTransferClientFactory = http.Client Function();

http.Client _defaultTransferClient() => http.Client();

/// How an [HttpBytesClient] runs file-bound GETs ([HttpBytesClient.transfer])
/// off the calling isolate.
///
/// A transfer's socket, its response body and the writes of that body into a
/// file all happen on one worker isolate the client spawns on first use;
/// the calling isolate sends the request and hears the head, each span
/// written and the end. The VM only: on the web
/// [HttpBytesClient.canTransfer] is false.
@immutable
final class HttpBytesTransfers {
  /// Transfers through a client [client] builds on the worker (the default
  /// `http.Client()`), writing the body in pieces of [landBytes] and failing
  /// a body that goes [receiveTimeout] without a byte.
  const HttpBytesTransfers({
    this.client = _defaultTransferClient,
    this.landBytes = 256 * 1024,
    this.receiveTimeout = const Duration(seconds: 15),
    this.onTransfer,
  }) : assert(landBytes > 0, 'landBytes must be > 0');

  /// Builds the worker's client, on the worker's isolate.
  final HttpBytesTransferClientFactory client;

  /// Bytes buffered before one write and one landing report.
  final int landBytes;

  /// The longest gap allowed between two pieces of a body. The client's
  /// middlewares see the request and the head of a transfer, not its body,
  /// so the worker applies this one itself.
  final Duration receiveTimeout;

  /// Told about every transfer when it ends, on the calling isolate: for a
  /// host's network diagnostics.
  final void Function(HttpBytesTransferRecord record)? onTransfer;
}

/// One transfer as [HttpBytesTransfers.onTransfer] reports it.
@immutable
final class HttpBytesTransferRecord {
  /// Creates the record of one transfer.
  const HttpBytesTransferRecord({
    required this.url,
    required this.range,
    required this.statusCode,
    required this.started,
    required this.head,
    required this.ended,
    required this.bytes,
    required this.failed,
  });

  /// What was fetched.
  final Uri url;

  /// The `Range` header sent, or null for the whole body.
  final String? range;

  /// The answer's status; 0 when no head arrived.
  final int statusCode;

  /// When the GET was sent, on the clock of [DateTime.now].
  final DateTime started;

  /// Send to head; null when no head arrived.
  final Duration? head;

  /// Send to the end of the body (or the failure).
  final Duration ended;

  /// Body bytes written.
  final int bytes;

  /// Whether the transfer failed or was cancelled.
  final bool failed;
}

/// A GET whose head has arrived and whose body waits on the worker
/// ([HttpBytesClient.transfer]).
///
/// Exactly one of [writeTo] and [cancel] is called: the transfer holds one
/// of the client's slots until its body ends, fails or is cancelled.
abstract interface class HttpBytesTransfer {
  /// The answer's status, headers and declared length; its body is not here.
  HttpBytesResponse get head;

  /// Writes the body into the file at [path], its first byte at [offset],
  /// creating the file when absent and leaving bytes outside the write as
  /// they are. [onLanded] hears each span `[start, end)` once it is in the
  /// file, in order, on the calling isolate; the next is not reported before
  /// the future [onLanded] returns completes. Completes when the body ended
  /// and every span was reported; fails with an [HttpBytesException] when
  /// the body failed, timed out, was cancelled or could not be written.
  Future<void> writeTo(
    String path, {
    required int offset,
    required FutureOr<void> Function(int start, int end) onLanded,
  });

  /// Drops the body: the GET is aborted and its slot freed.
  void cancel();
}
