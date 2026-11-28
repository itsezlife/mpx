import 'dart:io';

import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:test/test.dart';

/// Requests with no body: a protocol's control calls beside its uploads.
void main() {
  group('HttpBytesClient.request', () {
    late HttpServer server;
    late HttpBytesClient client;
    final received = <(String, Map<String, String>)>[];
    var status = 200;

    setUp(() async {
      status = 200;
      received.clear();
      server = (await HttpServer.bind(InternetAddress.loopbackIPv4, 0))
        ..listen((request) async {
          final headers = <String, String>{};
          request.headers.forEach(
            (name, values) => headers[name] = values.join(),
          );
          received.add((request.method, headers));
          await request.drain<void>();
          request.response
            ..statusCode = status
            ..headers.set('x-answer', 'seen');
          if (request.method != 'HEAD') request.response.write('body');
          await request.response.close();
        });
      client = HttpBytesClient();
    });

    tearDown(() async {
      await client.close();
      await server.close(force: true);
    });

    Uri url() => Uri.parse('http://${server.address.host}:${server.port}/u');

    test('sends the method and headers with no body, and answers the '
        'status, headers and body', () async {
      for (final method in ['HEAD', 'POST', 'DELETE']) {
        final response = await client.request(
          url(),
          method: method,
          headers: {'x-call': method},
        );
        expect(response.statusCode, 200);
        expect(response.headers['x-answer'], 'seen');
        expect(response.body, method == 'HEAD' ? isEmpty : 'body'.codeUnits);
      }
      expect(
        [for (final (method, _) in received) method],
        [
          'HEAD',
          'POST',
          'DELETE',
        ],
      );
      for (final (method, headers) in received) {
        expect(headers['x-call'], method);
        expect(headers['content-length'] ?? '0', '0');
      }
    });

    test('a GET is refused: GETs go through getBytes, stream or '
        'transfer', () {
      expect(
        () => client.request(url(), method: 'GET'),
        throwsArgumentError,
      );
    });

    test('a status that is not a success fails with it, sent once', () async {
      status = 503;
      await expectLater(
        client.request(url(), method: 'HEAD'),
        throwsA(
          isA<HttpBytesException>().having((e) => e.statusCode, 'status', 503),
        ),
      );
      expect(received, hasLength(1));
    });

    test('a status the caller accepts answers', () async {
      status = 404;
      final response = await client.request(
        url(),
        method: 'HEAD',
        context: {HttpBytesContext.validateStatusKey: (int _) => true},
      );
      expect(response.statusCode, 404);
    });
  });
}
