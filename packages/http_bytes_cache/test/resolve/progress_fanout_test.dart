import 'dart:async';
import 'dart:typed_data';

import 'package:cancel_token/cancel_token.dart';
import 'package:http/http.dart' as http;
import 'package:http_bytes_cache/src/http/http_bytes_client.dart';
import 'package:test/test.dart';

void main() {
  group('Progress fan-out', () {
    late _ControlledBodyClient server;
    late HttpBytesClient client;
    final url = Uri.parse('https://cdn.example.com/clip.mp4');

    setUp(() {
      server = _ControlledBodyClient(contentLength: 6);
      client = HttpBytesClient(client: server, middlewares: const []);
    });
    tearDown(() => client.close());

    test('every sharer hears progress, starting from 0', () async {
      final a = <(int, int?)>[];
      final b = <(int, int?)>[];
      final first = client.getBytes(
        url,
        onBytesProgress: (c, t) => a.add((c, t)),
      );
      final second = client.getBytes(
        url,
        onBytesProgress: (c, t) => b.add((c, t)),
      );
      await server.headersSent;
      server
        ..add([1, 2])
        ..add([3, 4, 5, 6]);
      await server.finish();

      final results = await (first, second).wait;
      expect(results.$1, [1, 2, 3, 4, 5, 6]);
      expect(results.$2, [1, 2, 3, 4, 5, 6]);
      expect(server.sends, 1);
      expect(a, [(0, 6), (2, 6), (6, 6)]);
      expect(b, [(0, 6), (2, 6), (6, 6)]);
    });

    test('a late joiner first hears the last value at once', () async {
      final late = <(int, int?)>[];
      final first = client.getBytes(url);
      await server.headersSent;
      server.add([1, 2]);
      await pumpEventQueue();

      final second = client.getBytes(
        url,
        onBytesProgress: (c, t) => late.add((c, t)),
      );
      await pumpEventQueue();
      expect(late, [(2, 6)]);

      server.add([3, 4, 5, 6]);
      await server.finish();
      await (first, second).wait;
      expect(late, [(2, 6), (6, 6)]);
    });

    test('cancelling one sharer leaves the other hearing progress', () async {
      final a = <(int, int?)>[];
      final b = <(int, int?)>[];
      final cancelA = CancelToken();
      final first = client.getBytes(
        url,
        cancelToken: cancelA,
        onBytesProgress: (c, t) => a.add((c, t)),
      );
      final second = client.getBytes(
        url,
        onBytesProgress: (c, t) => b.add((c, t)),
      );
      await server.headersSent;
      server.add([1, 2]);
      await pumpEventQueue();

      cancelA.cancel();
      await expectLater(
        first,
        throwsA(isA<HttpBytesException$Cancelled>()),
      );
      server.add([3, 4, 5, 6]);
      await server.finish();

      expect(await second, [1, 2, 3, 4, 5, 6]);
      expect(a, [(0, 6), (2, 6)]);
      expect(b, [(0, 6), (2, 6), (6, 6)]);
    });

    test('cancelling the starter keeps a joiner hearing progress', () async {
      final b = <(int, int?)>[];
      final cancelA = CancelToken();
      final first = client.getBytes(url, cancelToken: cancelA);
      final second = client.getBytes(
        url,
        onBytesProgress: (c, t) => b.add((c, t)),
      );
      await server.headersSent;
      cancelA.cancel();
      await expectLater(
        first,
        throwsA(isA<HttpBytesException$Cancelled>()),
      );
      server.add([1, 2, 3, 4, 5, 6]);
      await server.finish();

      expect(await second, [1, 2, 3, 4, 5, 6]);
      expect(b, [(0, 6), (6, 6)]);
    });
  });
}

/// One GET whose body the test pushes chunk by chunk.
final class _ControlledBodyClient extends http.BaseClient {
  _ControlledBodyClient({this.contentLength});

  final int? contentLength;
  final _body = StreamController<List<int>>();
  final _headers = Completer<void>();
  int sends = 0;

  Future<void> get headersSent => _headers.future;

  void add(List<int> chunk) => _body.add(Uint8List.fromList(chunk));

  Future<void> finish() => _body.close();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sends++;
    if (!_headers.isCompleted) _headers.complete();
    return http.StreamedResponse(
      _body.stream,
      200,
      contentLength: contentLength,
      request: request,
    );
  }
}
