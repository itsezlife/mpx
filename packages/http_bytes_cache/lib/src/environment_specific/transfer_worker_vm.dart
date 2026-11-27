import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_bytes_cache/src/http/http_bytes_transfer.dart';
import 'package:http_bytes_cache/src/http/http_bytes_upload.dart';
import 'package:http_bytes_cache/src/http/transfer_worker.dart';
import 'package:http_bytes_cache/src/isolate_controller.dart';

/// Whether this platform runs transfers on a worker isolate.
const bool $canTransfer = true;

/// Whether an upload can send an [HttpBytesUploadBody$Blob]: not on the VM.
const bool $canSendBlobs = false;

/// A [TransferWorker] over one isolate, spawned on the first GET.
TransferWorker $transferWorker(HttpBytesTransfers config) =>
    _IsolateTransferWorker(config);

/// Uploads go out from the transfer [worker]: one isolate and one HTTP
/// stack for both directions.
UploadSender $uploadSender(TransferWorker Function() worker) => worker();

/// Biggest answer body an upload keeps; a server sending more fails the
/// upload rather than filling the worker's memory.
const _maxAnswerBytes = 1024 * 1024;

final class _IsolateTransferWorker implements TransferWorker {
  _IsolateTransferWorker(this._config);

  final HttpBytesTransfers _config;
  IsolateController<_In, _Out>? _controller;
  Future<IsolateController<_In, _Out>>? _spawning;
  StreamSubscription<_Out>? _replies;
  final _heads = <int, Completer<TransferHead>>{};
  final _bodies = <int, _Body>{};
  final _uploads = <int, _PendingUpload>{};
  var _nextId = 0;
  var _closed = false;

  Future<IsolateController<_In, _Out>> _worker() {
    if (_closed) {
      return Future.error(
        const TransferFailed(TransferFailure.cancelled, 'the worker is closed'),
      );
    }
    return _spawning ??=
        IsolateController.spawn<_Config, _In, _Out>(
          handler: _transferHandler,
          payload: _Config(
            _config.client,
            _config.landBytes,
            _config.receiveTimeout,
          ),
          name: 'http_bytes_transfer',
        ).then((controller) {
          _controller = controller;
          _replies = controller.stream.listen(
            _onReply,
            onDone: () => _failAll('the transfer worker ended'),
          );
          return controller;
        });
  }

  @override
  Future<TransferHead> get(
    Uri url,
    Map<String, String> headers, {
    required Future<void> abort,
  }) async {
    final worker = await _worker();
    final id = _nextId++;
    final head = _heads[id] = Completer<TransferHead>();
    worker.add(_Get(id, url, headers));
    unawaited(
      abort.then((_) {
        if (_closed || !_owns(id)) return;
        worker.add(_Abort(id));
      }),
    );
    return head.future;
  }

  bool _owns(int id) =>
      _heads.containsKey(id) ||
      _bodies.containsKey(id) ||
      _uploads.containsKey(id);

  @override
  Future<UploadAnswer> upload({
    required String method,
    required Uri url,
    required Map<String, String> headers,
    required HttpBytesUploadBody body,
    required Future<void> abort,
    required void Function(int sent) onSent,
  }) async {
    final path = switch (body) {
      HttpBytesUploadBody$File(:final path) => path,
      HttpBytesUploadBody$Blob() => throw UnsupportedError(
        'A blob body is for the web; on the VM upload a file.',
      ),
    };
    final worker = await _worker();
    final id = _nextId++;
    final pending = _uploads[id] = _PendingUpload(onSent);
    worker.add(
      _Upload(
        id,
        method,
        url,
        headers,
        path,
        body.offset,
        body.length,
        body.prefix,
        body.suffix,
      ),
    );
    unawaited(
      abort.then((_) {
        if (_closed || !_owns(id)) return;
        worker.add(_Abort(id));
      }),
    );
    return pending.answer.future;
  }

  @override
  Future<void> write(
    TransferHead head,
    String path,
    int offset,
    FutureOr<void> Function(int start, int end) onLanded,
  ) {
    final worker = _controller;
    if (worker == null || _closed) {
      return Future.error(
        const TransferFailed(TransferFailure.cancelled, 'the worker is closed'),
      );
    }
    final body = _bodies[head.id];
    if (body == null) {
      return Future.error(
        const TransferFailed(TransferFailure.cancelled, 'the body is gone'),
      );
    }
    body.onLanded = onLanded;
    worker.add(_Write(head.id, path, offset));
    return body.result;
  }

  @override
  void discard(TransferHead head) {
    final body = _bodies.remove(head.id);
    if (body == null || _closed) return;
    _controller?.add(_Abort(head.id));
    body.end();
  }

  void _onReply(_Out reply) {
    switch (reply) {
      case _Head(:final id, :final statusCode, :final headers, :final length):
        final head = _heads.remove(id);
        if (head == null) return;
        _bodies[id] = _Body();
        head.complete(
          TransferHead(
            id: id,
            statusCode: statusCode,
            headers: headers,
            contentLength: length,
          ),
        );
      case _Landed(:final id, :final start, :final end):
        final body = _bodies[id];
        if (body == null) return;
        body.chain = body.chain.then((_) {
          if (body.failed) return null;
          return body.onLanded?.call(start, end);
        });
        body.chain.then(
          (_) {},
          onError: (Object error, StackTrace stackTrace) {
            // A report that throws ends the transfer: its bytes may stay
            // in the file, but nobody counts them.
            if (body.failed) return;
            body.failed = true;
            _controller?.add(_Abort(id));
            body.end(error, stackTrace);
          },
        );
      case _Done(:final id):
        final body = _bodies.remove(id);
        if (body == null) return;
        body.chain.then((_) {
          body.end();
        }, onError: (Object _) {});
      case _Sent(:final id, :final sent):
        _uploads[id]?.onSent(sent);
      case _Answer(:final id, :final statusCode, :final headers, :final body):
        _uploads
            .remove(id)
            ?.answer
            .complete(
              UploadAnswer(
                statusCode: statusCode,
                headers: headers,
                body: body,
              ),
            );
      case _Failed(:final id, :final kind, :final message):
        final failure = TransferFailed(kind, message);
        final head = _heads.remove(id);
        if (head != null) {
          head.completeError(failure);
          return;
        }
        final upload = _uploads.remove(id);
        if (upload != null) {
          upload.answer.completeError(failure);
          return;
        }
        final body = _bodies.remove(id);
        if (body == null) return;
        body.chain.then((_) {
          body.end(failure);
        }, onError: (Object _) {});
    }
  }

  void _failAll(String why) {
    final failure = TransferFailed(TransferFailure.cancelled, why);
    for (final head in _heads.values) {
      if (!head.isCompleted) head.completeError(failure);
    }
    for (final body in _bodies.values) {
      body.end(failure);
    }
    for (final upload in _uploads.values) {
      upload.answer.completeError(failure);
    }
    _heads.clear();
    _bodies.clear();
    _uploads.clear();
    _controller = null;
    _spawning = null;
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    final controller = _controller;
    _failAll('the transfer worker was closed');
    unawaited(_replies?.cancel());
    controller?.close();
  }
}

/// A body on its way into a file, seen from the calling isolate.
final class _Body {
  FutureOr<void> Function(int start, int end)? onLanded;

  /// The reports, one after the other.
  Future<void> chain = Future<void>.value();

  /// Completes, never with an error, when the body ends; [error] says how.
  ///
  /// A transfer aborted between its head and its write (a preload cancelled
  /// as its item leaves the window) ends with nobody awaiting yet, and a
  /// future that completes with an error and has no listener is the zone's
  /// uncaught error. So the failure travels as a value and is thrown to the
  /// write that comes later, by the future it is given.
  final Completer<void> done = Completer<void>();
  Object? error;
  StackTrace? stackTrace;
  bool failed = false;

  void end([Object? error, StackTrace? stackTrace]) {
    if (done.isCompleted) return;
    this.error = error;
    this.stackTrace = stackTrace;
    done.complete();
  }

  Future<void> get result => done.future.then((_) {
    final failure = error;
    if (failure != null) {
      Error.throwWithStackTrace(failure, stackTrace ?? StackTrace.current);
    }
  });
}

/// An upload waiting for its answer, seen from the calling isolate.
final class _PendingUpload {
  _PendingUpload(this.onSent);

  final void Function(int sent) onSent;
  final Completer<UploadAnswer> answer = Completer<UploadAnswer>();
}

// --- Protocol (data, not control flow) ---

final class _Config {
  const _Config(this.client, this.landBytes, this.receiveTimeout);
  final HttpBytesTransferClientFactory client;
  final int landBytes;
  final Duration receiveTimeout;
}

sealed class _In {
  const _In(this.id);
  final int id;
}

final class _Get extends _In {
  const _Get(super.id, this.url, this.headers);
  final Uri url;
  final Map<String, String> headers;
}

final class _Write extends _In {
  const _Write(super.id, this.path, this.offset);
  final String path;
  final int offset;
}

final class _Upload extends _In {
  const _Upload(
    super.id,
    this.method,
    this.url,
    this.headers,
    this.path,
    this.offset,
    this.length,
    this.prefix,
    this.suffix,
  );
  final String method;
  final Uri url;
  final Map<String, String> headers;
  final String path;
  final int offset;
  final int length;
  final List<int> prefix;
  final List<int> suffix;
}

final class _Abort extends _In {
  const _Abort(super.id);
}

sealed class _Out {
  const _Out(this.id);
  final int id;
}

final class _Head extends _Out {
  const _Head(super.id, this.statusCode, this.headers, this.length);
  final int statusCode;
  final Map<String, String> headers;
  final int? length;
}

final class _Landed extends _Out {
  const _Landed(super.id, this.start, this.end);
  final int start;
  final int end;
}

final class _Done extends _Out {
  const _Done(super.id);
}

final class _Sent extends _Out {
  const _Sent(super.id, this.sent);
  final int sent;
}

final class _Answer extends _Out {
  const _Answer(super.id, this.statusCode, this.headers, this.body);
  final int statusCode;
  final Map<String, String> headers;
  final Uint8List body;
}

final class _Failed extends _Out {
  const _Failed(super.id, this.kind, this.message);
  final TransferFailure kind;
  final String message;
}

// --- The isolate side ---

/// One GET on the worker: aborted through [abort], its response kept until
/// a write or an abort says what to do with the body.
final class _Running {
  final Completer<void> abort = Completer<void>();
  http.StreamedResponse? response;
  // Cancelled by the abort or the failure that ends the transfer, or done
  // with the body.
  // ignore: cancel_subscriptions
  StreamSubscription<List<int>>? body;
  Timer? idle;
  bool aborted = false;
}

/// One upload on the worker, aborted through [abort].
final class _Sending {
  final Completer<void> abort = Completer<void>();
  Timer? idle;
}

/// A request whose body is a stream the client pulls as the socket takes
/// it, so a range of any size goes out through a bounded buffer.
/// [http.StreamedRequest] would take the bytes through a sink with no back
/// pressure, and buffer as much as the file reads faster than the network.
final class _StreamBodyRequest extends http.BaseRequest
    implements http.Abortable {
  _StreamBodyRequest(super.method, super.url, this._body, this.abortTrigger);

  final Stream<List<int>> _body;

  @override
  final Future<void>? abortTrigger;

  @override
  http.ByteStream finalize() {
    super.finalize();
    return http.ByteStream(_body);
  }
}

Future<void> _transferHandler(
  _Config config,
  Stream<_In> messages,
  void Function(_Out out) send,
) async {
  final client = config.client();
  final running = <int, _Running>{};
  final uploads = <int, _Sending>{};

  void abort(int id) {
    final upload = uploads.remove(id);
    if (upload != null) {
      upload.idle?.cancel();
      if (!upload.abort.isCompleted) upload.abort.complete();
      send(_Failed(id, TransferFailure.cancelled, 'aborted'));
      return;
    }
    final transfer = running.remove(id);
    if (transfer == null) return;
    transfer
      ..aborted = true
      ..idle?.cancel();
    if (!transfer.abort.isCompleted) transfer.abort.complete();
    unawaited(transfer.body?.cancel());
    // A body nobody listened to still holds its socket until drained or
    // cancelled.
    if (transfer.body == null) {
      transfer.response?.stream.listen(null).cancel().ignore();
    }
    send(_Failed(id, TransferFailure.cancelled, 'aborted'));
  }

  Future<void> get(_Get message) async {
    final transfer = running[message.id] = _Running();
    final request =
        http.AbortableRequest(
            'GET',
            message.url,
            abortTrigger: transfer.abort.future,
          )
          ..headers.addAll(message.headers)
          ..followRedirects = true;
    try {
      final response = await client.send(request);
      if (transfer.aborted) {
        response.stream.listen(null).cancel().ignore();
        return;
      }
      transfer.response = response;
      send(
        _Head(
          message.id,
          response.statusCode,
          response.headers,
          response.contentLength,
        ),
      );
    } on Object catch (error) {
      if (transfer.aborted) return;
      running.remove(message.id);
      send(
        _Failed(
          message.id,
          error is http.RequestAbortedException
              ? TransferFailure.cancelled
              : TransferFailure.network,
          '$error',
        ),
      );
    }
  }

  void write(_Write message) {
    final id = message.id;
    final transfer = running[id];
    final response = transfer?.response;
    if (transfer == null || response == null) return;
    final pending = BytesBuilder(copy: false);
    var offset = message.offset;

    void fail(TransferFailure kind, String why) {
      if (running.remove(id) == null) return;
      transfer.idle?.cancel();
      if (!transfer.abort.isCompleted) transfer.abort.complete();
      unawaited(transfer.body?.cancel());
      send(_Failed(id, kind, why));
    }

    // Written and reported in pieces of at most landBytes, however the
    // socket cut the body: a reader waiting on the first bytes of a large
    // chunk hears them first.
    bool flush() {
      if (pending.isEmpty) return true;
      final bytes = pending.takeBytes();
      for (var at = 0; at < bytes.length; at += config.landBytes) {
        final end = at + config.landBytes < bytes.length
            ? at + config.landBytes
            : bytes.length;
        try {
          _writeAt(message.path, offset, Uint8List.sublistView(bytes, at, end));
        } on FileSystemException catch (error) {
          fail(TransferFailure.io, '$error');
          return false;
        }
        send(_Landed(id, offset, offset + end - at));
        offset += end - at;
      }
      return true;
    }

    void armIdle() {
      transfer.idle?.cancel();
      transfer.idle = Timer(config.receiveTimeout, () {
        fail(
          TransferFailure.timeout,
          'no data for ${config.receiveTimeout.inMilliseconds} ms',
        );
      });
    }

    armIdle();
    transfer.body = response.stream.listen(
      (chunk) {
        armIdle();
        pending.add(chunk);
        if (pending.length >= config.landBytes) flush();
      },
      onError: (Object error) {
        if (transfer.aborted) return;
        fail(
          error is http.RequestAbortedException
              ? TransferFailure.cancelled
              : TransferFailure.network,
          '$error',
        );
      },
      onDone: () {
        transfer.idle?.cancel();
        if (!running.containsKey(id)) return;
        if (!flush()) return;
        running.remove(id);
        send(_Done(id));
      },
      cancelOnError: true,
    );
  }

  Future<void> upload(_Upload message) async {
    final id = message.id;
    final sending = uploads[id] = _Sending();

    void fail(TransferFailure kind, String why) {
      if (uploads.remove(id) == null) return;
      sending.idle?.cancel();
      if (!sending.abort.isCompleted) sending.abort.complete();
      send(_Failed(id, kind, why));
    }

    // One idle gap for the whole exchange: the body going out, the wait for
    // the head while the server takes it in, and the answer's body.
    void armIdle() {
      sending.idle?.cancel();
      sending.idle = Timer(config.receiveTimeout, () {
        fail(
          TransferFailure.timeout,
          'no progress for ${config.receiveTimeout.inMilliseconds} ms',
        );
      });
    }

    final end = message.offset + message.length;
    try {
      final available = await File(message.path).length();
      if (available < end) {
        fail(
          TransferFailure.io,
          'the file has $available bytes, the body ends at $end',
        );
        return;
      }
    } on FileSystemException catch (error) {
      fail(TransferFailure.io, '$error');
      return;
    }
    if (!uploads.containsKey(id)) return;

    var sent = 0;
    var reported = 0;
    final total =
        message.prefix.length + message.length + message.suffix.length;
    Stream<List<int>> framed() async* {
      if (message.prefix.isNotEmpty) yield message.prefix;
      yield* File(message.path).openRead(message.offset, end);
      if (message.suffix.isNotEmpty) yield message.suffix;
    }

    final body = framed().map((chunk) {
      armIdle();
      sent += chunk.length;
      // Reported in steps of landBytes, the cadence transfers land at, and
      // once at the end.
      if (sent - reported >= config.landBytes || sent == total) {
        reported = sent;
        send(_Sent(id, sent));
      }
      return chunk;
    });
    final request =
        _StreamBodyRequest(
            message.method,
            message.url,
            body,
            sending.abort.future,
          )
          ..headers.addAll(message.headers)
          ..contentLength = total
          // A redirect would have to send the body again, which a stream
          // cannot.
          ..followRedirects = false;
    armIdle();
    try {
      final response = await client.send(request);
      armIdle();
      final answer = BytesBuilder(copy: false);
      await for (final chunk in response.stream) {
        armIdle();
        answer.add(chunk);
        if (answer.length > _maxAnswerBytes) {
          fail(
            TransferFailure.network,
            'the answer body is over $_maxAnswerBytes bytes',
          );
          return;
        }
      }
      if (uploads.remove(id) == null) return;
      sending.idle?.cancel();
      send(
        _Answer(id, response.statusCode, response.headers, answer.takeBytes()),
      );
    } on Object catch (error) {
      fail(switch (error) {
        http.RequestAbortedException() => TransferFailure.cancelled,
        FileSystemException() => TransferFailure.io,
        _ => TransferFailure.network,
      }, '$error');
    }
  }

  await for (final message in messages) {
    switch (message) {
      case _Upload():
        unawaited(upload(message));
      case _Get():
        unawaited(get(message));
      case _Write():
        write(message);
      case _Abort(:final id):
        abort(id);
    }
  }
  client.close();
}

/// Writes in place: the file grows by offset writes, never by replacing it,
/// so a native reader holding it open sees every write. Opened per write, so
/// a file put in its place since (a reset) is the one written.
void _writeAt(String path, int offset, Uint8List bytes) {
  final file = File(path);
  final handle = file.openSync(mode: FileMode.append);
  try {
    handle
      ..setPositionSync(offset)
      ..writeFromSync(bytes);
  } finally {
    handle.closeSync();
  }
}
