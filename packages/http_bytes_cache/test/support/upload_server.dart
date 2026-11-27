import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// One request an [UploadServer] took in.
final class ReceivedUpload {
  ReceivedUpload(this.method, this.path, this.headers);

  final String method;
  final String path;
  final Map<String, String> headers;

  /// Body bytes received (all of them, also when not [kept]).
  int length = 0;

  /// The first and the last byte of the body, null while it is empty.
  int? first;
  int? last;

  /// The body, while it is at most [UploadServer.keepUpTo] bytes.
  final BytesBuilder kept = BytesBuilder(copy: false);

  /// Whether the body ended: the request was read to its end.
  bool complete = false;

  /// Byte `i` of the body differed from `(start + i) % 251`, when
  /// [UploadServer.patternStart] is set; null while every byte matched.
  int? firstMismatch;
}

/// A local HTTP server that reads request bodies without keeping them (past
/// [keepUpTo]) and answers with [statuses] in turn, then 200 with [answer].
final class UploadServer {
  UploadServer._(this._server);

  static Future<UploadServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final upload = UploadServer._(server);
    server.listen(upload._handle);
    return upload;
  }

  final HttpServer _server;

  /// Statuses answered before the first 200, one per request.
  final List<int> statuses = [];

  /// The body of a 200.
  List<int> answer = 'ok'.codeUnits;

  /// Bodies up to this many bytes are kept in [ReceivedUpload.kept].
  int keepUpTo = 1024 * 1024;

  /// When set, bodies are checked against the pattern `(start + i) % 251`.
  int? patternStart;

  /// When set, a body read stops (the request hangs) after this many bytes
  /// until [release] completes.
  int? holdAfter;
  Completer<void> release = Completer<void>();

  /// Completes when a held body reaches [holdAfter].
  Completer<void> held = Completer<void>();

  /// Requests in arrival order.
  final List<ReceivedUpload> received = [];

  Uri url([String path = '/upload?token=secret']) =>
      Uri.parse('http://${_server.address.host}:${_server.port}$path');

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final headers = <String, String>{};
    request.headers.forEach((name, values) => headers[name] = values.join(','));
    final upload = ReceivedUpload(request.method, request.uri.path, headers);
    received.add(upload);
    final start = patternStart;
    try {
      await for (final chunk in request) {
        if (start != null) {
          for (var i = 0; i < chunk.length; i++) {
            if (upload.firstMismatch == null &&
                chunk[i] != (start + upload.length + i) % 251) {
              upload.firstMismatch = upload.length + i;
            }
          }
        }
        if (chunk.isNotEmpty) {
          upload
            ..first ??= chunk.first
            ..last = chunk.last;
        }
        if (upload.length + chunk.length <= keepUpTo) upload.kept.add(chunk);
        upload.length += chunk.length;
        final hold = holdAfter;
        if (hold != null && upload.length >= hold) {
          if (!held.isCompleted) held.complete();
          await release.future;
        }
      }
      upload.complete = true;
    } on Object {
      return;
    }
    final status = statuses.isEmpty ? 200 : statuses.removeAt(0);
    request.response.statusCode = status;
    if (status == 200) request.response.add(answer);
    await request.response.close();
  }
}

/// Writes a file of [length] bytes holding `i % 251` at byte `i`, in pieces.
File patternFile(String path, int length) {
  final file = File(path);
  final sink = file.openSync(mode: FileMode.write);
  const piece = 251 * 4096;
  final block = Uint8List.fromList([for (var i = 0; i < piece; i++) i % 251]);
  try {
    for (var at = 0; at < length; at += piece) {
      final end = at + piece < length ? at + piece : length;
      sink.writeFromSync(block, 0, end - at);
    }
  } finally {
    sink.closeSync();
  }
  return file;
}
