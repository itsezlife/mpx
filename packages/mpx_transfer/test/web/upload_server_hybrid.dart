// The upload test server for the browser tests, run on the VM beside the
// page (`spawnHybridUri`): the three protocols of test/support behind a
// proxy that answers the browser's CORS checks.
//
// The channel's first message is the proxy's URL. Then each request
// `{id, op, ...}` is answered `{id, result}`:
// - `call` {method, path, body}: the host's own call on the numbered
//   protocol (start, complete), answered {status, body};
// - `file` {file}: the bytes of a file a protocol completed (a tus file
//   by its upload's URL), or null;
// - `breakAt` {bytes}: the next tus PATCH stops once its upload holds that
//   many bytes; answered once one did;
// - `release`: the PATCH held by `breakAt` drops.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:stream_channel/stream_channel.dart';

import '../support/multipart_protocol.dart';
import '../support/tus_protocol.dart';
import '../support/upload_test_server.dart';

Future<void> hybridMain(StreamChannel<Object?> channel) async {
  final server = await UploadTestServer.start();
  MultipartProtocol(server);
  final tus = TusProtocol(server);
  final numbered = _Numbered(server);
  final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final origin = '${server.url('')}';
  final proxied = 'http://${proxy.address.host}:${proxy.port}';
  proxy.listen((request) => unawaited(_forward(request, origin, proxied)));
  channel.sink.add(proxied);

  await for (final message in channel.stream) {
    final request = message! as Map<Object?, Object?>;
    final Object? result;
    switch (request['op']) {
      case 'call':
        final answer = numbered.call(
          request['path']! as String,
          jsonDecode(request['body']! as String) as Map<String, Object?>,
        );
        result = {'status': answer.status, 'body': jsonEncode(answer.body)};
      case 'file':
        final file = request['file']! as String;
        // A tus file is named by its upload's URL.
        result = (server.files[file] ?? tus.uploadAt(file)?.bytes.toBytes())
            ?.toList();
      case 'breakAt':
        tus
          ..breakAt = request['bytes']! as int
          ..broke = Completer<void>()
          ..release = Completer<void>();
        await tus.broke.future;
        result = true;
      case 'release':
        tus.release.complete();
        result = true;
      default:
        result = null;
    }
    channel.sink.add({'id': request['id'], 'result': result});
  }
  await proxy.close(force: true);
  await server.close();
}

const Map<String, String> _cors = {
  'access-control-allow-origin': '*',
  'access-control-allow-methods': 'GET, HEAD, POST, PUT, PATCH, OPTIONS',
  'access-control-allow-headers': '*',
  'access-control-expose-headers': '*',
};

/// Answers a CORS preflight itself; sends anything else on to [origin],
/// read whole, and its answer back with the CORS headers, absolute URLs of
/// [origin] rewritten to [proxied].
Future<void> _forward(
  HttpRequest request,
  String origin,
  String proxied,
) async {
  final response = request.response;
  _cors.forEach(response.headers.set);
  if (request.method == 'OPTIONS') {
    response.statusCode = 204;
    await response.close();
    return;
  }
  final body = BytesBuilder(copy: false);
  await request.forEach(body.add);
  final client = HttpClient();
  try {
    final out = await client.openUrl(
      request.method,
      Uri.parse('$origin${request.uri}'),
    );
    request.headers.forEach((name, values) {
      if (name == 'host' || name == 'content-length') return;
      for (final value in values) {
        out.headers.add(name, value);
      }
    });
    final bytes = body.takeBytes();
    out
      ..contentLength = bytes.length
      ..add(bytes);
    final answer = await out.close();
    response.statusCode = answer.statusCode;
    answer.headers.forEach((name, values) {
      if (name == 'content-length' || name == 'transfer-encoding') return;
      response.headers.set(
        name,
        values.map((value) => value.replaceAll(origin, proxied)).join(','),
      );
    });
    await answer.forEach(response.add);
  } on Object {
    // The server dropped the request (a tus PATCH broken off): a failure
    // the client may try again.
    response.statusCode = 503;
  } finally {
    client.close();
  }
  await response.close();
}

/// A host's numbered-parts protocol, kept to what the browser tests need
/// (the VM's support file builds transports, which the VM side here cannot
/// import): `PUT /numbered/<id>/<n>` takes part n and answers an
/// `x-part-id` header; [call] starts an upload (`/numbered/start`,
/// answering its `uploadId`) and completes it (`/numbered/<id>/complete`
/// with its parts, answering the `file` id in [UploadTestServer.files]).
final class _Numbered {
  _Numbered(this.server) {
    server.mount('/numbered/', _part);
  }

  final UploadTestServer server;
  final Map<String, Map<int, Uint8List>> _uploads = {};
  int _next = 0;

  ({int status, Map<String, Object?> body}) call(
    String path,
    Map<String, Object?> body,
  ) {
    final segments = Uri.parse(path).pathSegments.skip(1).toList();
    switch (segments) {
      case ['start']:
        final id = 'n${_next++}';
        _uploads[id] = {};
        return (status: 200, body: {'uploadId': id});
      case [final id, 'complete']:
        final parts = _uploads.remove(id);
        if (parts == null) return (status: 404, body: const {});
        final file = BytesBuilder(copy: false);
        for (final part in body['parts']! as List<Object?>) {
          final number = (part! as Map<String, Object?>)['number']! as int;
          file.add(parts[number]!);
        }
        final fileId = server.nextFileId();
        server.files[fileId] = file.takeBytes();
        return (status: 200, body: {'file': fileId});
      default:
        return (status: 404, body: const {});
    }
  }

  TestAnswer _part(ReceivedRequest request) {
    final segments = request.uri.pathSegments.skip(1).toList();
    if (request.method != 'PUT' || segments.length != 2) {
      return const TestAnswer(405);
    }
    final parts = _uploads[segments[0]];
    final number = int.tryParse(segments[1]);
    if (parts == null || number == null) return const TestAnswer(404);
    parts[number] = request.body;
    return TestAnswer(200, headers: {'x-part-id': 'part-$number'});
  }
}
