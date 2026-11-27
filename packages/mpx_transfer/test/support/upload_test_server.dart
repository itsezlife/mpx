import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// One request as the [UploadTestServer] received it: read whole.
final class ReceivedRequest {
  ReceivedRequest(this.method, this.uri, this.headers, this.body);

  final String method;
  final Uri uri;

  /// Header names in lower case, values joined by `,`.
  final Map<String, String> headers;
  final Uint8List body;
}

/// What a protocol answers to a request: a status, headers and a body.
final class TestAnswer {
  const TestAnswer(
    this.status, {
    this.headers = const {},
    this.body = const [],
  });

  final int status;
  final Map<String, String> headers;
  final List<int> body;
}

/// A protocol mounted on the server: answers the requests under its path.
typedef TestProtocol = FutureOr<TestAnswer> Function(ReceivedRequest request);

/// A local HTTP server for the upload adapters' tests: each adapter's
/// protocol mounts under a path of its own ([mount]); the server records
/// every request ([requests]), keeps the files the protocols complete
/// ([files], by the id their answers name) and can answer the next
/// requests with given statuses first ([failNext]) or hold them
/// ([holdNext]).
final class UploadTestServer {
  UploadTestServer._(this._server) {
    _server.listen((request) => unawaited(_handle(request)));
  }

  /// Starts a server on a free loopback port.
  static Future<UploadTestServer> start() async => UploadTestServer._(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
  );

  final HttpServer _server;
  final Map<String, TestProtocol> _protocols = {};
  final List<int> _statuses = [];
  int _holds = 0;
  final List<Completer<void>> _held = [];

  /// Requests in arrival order, each recorded once its body is in.
  final List<ReceivedRequest> requests = [];

  /// The files the protocols completed, by id.
  final Map<String, Uint8List> files = {};

  /// Ids for [files]: `file-1`, `file-2` ...
  String nextFileId() => 'file-${files.length + 1}';

  /// The URL of [path] on this server.
  Uri url(String path) =>
      Uri.parse('http://${_server.address.host}:${_server.port}$path');

  /// Answers requests whose path starts with [path] through [protocol].
  void mount(String path, TestProtocol protocol) => _protocols[path] = protocol;

  /// Answers the next requests with [statuses], one each, before any
  /// protocol sees them.
  void failNext(List<int> statuses) => _statuses.addAll(statuses);

  /// Holds the next [count] requests once their bodies are in, unanswered
  /// until the server closes.
  void holdNext([int count = 1]) => _holds += count;

  Future<void> close() async {
    for (final held in _held) {
      if (!held.isCompleted) held.complete();
    }
    await _server.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    final headers = <String, String>{};
    request.headers.forEach((name, values) => headers[name] = values.join(','));
    final body = BytesBuilder(copy: false);
    try {
      await request.forEach(body.add);
    } on Object {
      return;
    }
    final received = ReceivedRequest(
      request.method,
      request.uri,
      headers,
      body.takeBytes(),
    );
    requests.add(received);
    if (_holds > 0) {
      _holds--;
      final held = Completer<void>();
      _held.add(held);
      await held.future;
      return;
    }
    final TestAnswer answer;
    if (_statuses.isNotEmpty) {
      answer = TestAnswer(_statuses.removeAt(0));
    } else {
      final protocol = _protocols.entries
          .where((entry) => request.uri.path.startsWith(entry.key))
          .map((entry) => entry.value)
          .firstOrNull;
      answer = protocol == null
          ? const TestAnswer(404)
          : await protocol(received);
    }
    try {
      request.response.statusCode = answer.status;
      answer.headers.forEach(request.response.headers.set);
      request.response.add(answer.body);
      await request.response.close();
    } on Object {
      // The client went away.
    }
  }
}
