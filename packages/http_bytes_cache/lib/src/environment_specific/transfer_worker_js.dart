import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:http_bytes_cache/src/http/http_bytes_transfer.dart';
import 'package:http_bytes_cache/src/http/http_bytes_upload.dart';
import 'package:http_bytes_cache/src/http/transfer_worker.dart';
import 'package:web/web.dart' as web;

/// Whether this platform runs transfers on a worker isolate: not on the web,
/// which has no isolate to give a socket to.
const bool $canTransfer = false;

/// Whether an upload can send an [HttpBytesUploadBody$Blob]: on the web.
const bool $canSendBlobs = true;

/// Never called on the web ([$canTransfer] is false).
TransferWorker $transferWorker(HttpBytesTransfers config) =>
    throw UnsupportedError('There are no transfer workers on the web.');

/// Uploads go out on the main thread through `fetch`; [worker] is not used.
UploadSender $uploadSender(TransferWorker Function() worker) =>
    const _FetchUploadSender();

/// Sends the body as a `Blob` slice: the browser reads it from the file as
/// the request goes out, so the bytes never become a Dart buffer.
///
/// `fetch` reports no upload progress: [UploadSender.upload]'s `onSent`
/// hears the length once the answer's head is in.
final class _FetchUploadSender implements UploadSender {
  const _FetchUploadSender();

  @override
  Future<UploadAnswer> upload({
    required String method,
    required Uri url,
    required Map<String, String> headers,
    required HttpBytesUploadBody body,
    required Future<void> abort,
    required void Function(int sent) onSent,
  }) async {
    final controller = web.AbortController();
    var aborted = false;
    unawaited(
      abort.then((_) {
        aborted = true;
        controller.abort();
      }),
    );
    final source = await _source(body);
    final end = body.offset + body.length;
    if (source.size < end) {
      throw TransferFailed(
        TransferFailure.io,
        'the source has ${source.size} bytes, the body ends at $end',
      );
    }
    final range = source.slice(body.offset, end);
    final slice = body.prefix.isEmpty && body.suffix.isEmpty
        ? range
        : web.Blob(
            <JSAny>[
              Uint8List.fromList(body.prefix).toJS,
              range,
              Uint8List.fromList(body.suffix).toJS,
            ].toJS,
          );
    final requestHeaders = web.Headers();
    for (final MapEntry(:key, :value) in headers.entries) {
      requestHeaders.append(key, value);
    }
    try {
      final response = await web.window
          .fetch(
            url.toString().toJS,
            web.RequestInit(
              method: method,
              headers: requestHeaders,
              body: slice,
              signal: controller.signal,
              redirect: 'manual',
            ),
          )
          .toDart;
      onSent(body.contentLength);
      final buffer = await response.arrayBuffer().toDart;
      final answerHeaders = <String, String>{};
      response.headers.callMethodVarArgs<JSAny?>('forEach'.toJS, [
        ((JSString value, JSString name) {
          answerHeaders[name.toDart.toLowerCase()] = value.toDart;
        }).toJS,
      ]);
      return UploadAnswer(
        statusCode: response.status,
        headers: answerHeaders,
        body: buffer.toDart.asUint8List(),
      );
    } on Object catch (error) {
      if (aborted) {
        throw const TransferFailed(TransferFailure.cancelled, 'aborted');
      }
      if (error is TransferFailed) rethrow;
      throw TransferFailed(TransferFailure.network, '$error');
    }
  }

  static Future<web.Blob> _source(HttpBytesUploadBody body) async {
    switch (body) {
      case HttpBytesUploadBody$Blob(:final blob):
        if (blob case final JSAny js when js.isA<web.Blob>()) {
          return js as web.Blob;
        }
        throw ArgumentError.value(blob, 'blob', 'is not a Blob');
      case HttpBytesUploadBody$File(:final path):
        try {
          var directory = await web.window.navigator.storage
              .getDirectory()
              .toDart;
          final segments = path.split('/').where((s) => s.isNotEmpty).toList();
          for (final name in segments.take(segments.length - 1)) {
            directory = await directory.getDirectoryHandle(name).toDart;
          }
          final handle = await directory.getFileHandle(segments.last).toDart;
          return await handle.getFile().toDart;
        } on Object catch (error) {
          throw TransferFailed(TransferFailure.io, '$error');
        }
    }
  }
}
