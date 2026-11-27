// A VM-side server for the browser upload test, started with
// `spawnHybridUri`: it echoes each request body back, with CORS headers so
// the test page may read the answer.
import 'dart:io';

// The channel is a StreamChannel; typed dynamic to keep stream_channel out of
// the package's dependencies for one test file.
// ignore: avoid_annotating_with_dynamic
Future<void> hybridMain(dynamic channel) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    request.response.headers
      ..set('access-control-allow-origin', '*')
      ..set('access-control-allow-methods', 'POST, PUT, PATCH')
      ..set('access-control-allow-headers', '*')
      ..set('access-control-expose-headers', 'x-method');
    final body = await request.fold<List<int>>(
      [],
      (all, chunk) => all..addAll(chunk),
    );
    request.response.headers.set('x-method', request.method);
    request.response.add(body);
    await request.response.close();
  });
  // ignore: avoid_dynamic_calls
  channel.sink.add(server.port);
}
