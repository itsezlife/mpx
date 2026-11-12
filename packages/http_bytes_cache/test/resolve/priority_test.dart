import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:test/test.dart';

void main() {
  group('Request priorities', () {
    late Completer<void> blocker;
    late List<String> served;
    late HttpBytesClient client;

    Uri url(String name) => Uri.parse('https://cdn.example.com/$name');

    Future<void> get(
      String name, [
      RequestPriority priority = RequestPriority.visible,
    ]) => client.getBytes(url(name), priority: PriorityToken(priority));

    setUp(() {
      blocker = Completer<void>();
      served = [];
      client = HttpBytesClient(
        maxConcurrent: 1,
        middlewares: const [],
        client: MockClient((request) async {
          final name = request.url.pathSegments.last;
          served.add(name);
          if (name == 'blocker') await blocker.future;
          return http.Response.bytes([1], 200);
        }),
      );
      addTearDown(client.close);
    });

    Future<void> drain(List<Future<void>> pending) async {
      blocker.complete();
      await Future.wait(pending);
    }

    test('the queue serves by priority, then arrival', () async {
      final pending = [
        get('blocker'),
        get('background', RequestPriority.background),
        get('preload', RequestPriority.preload),
        get('visible-1'),
        get('visible-2'),
      ];
      await pumpEventQueue();
      await drain(pending);

      expect(served, [
        'blocker',
        'visible-1',
        'visible-2',
        'preload',
        'background',
      ]);
    });

    test('a queued request can be promoted', () async {
      final promoted = PriorityToken(RequestPriority.background);
      final pending = [
        get('blocker'),
        client.getBytes(url('cell'), priority: promoted),
        get('preload', RequestPriority.preload),
      ];
      await pumpEventQueue();
      promoted.priority = RequestPriority.visible;
      await drain(pending);

      expect(served, ['blocker', 'cell', 'preload']);
    });

    test(
      'a coalesced request takes the highest priority of its callers',
      () async {
        final pending = [
          get('blocker'),
          get('shared', RequestPriority.background),
          get('preload', RequestPriority.preload),
          get('shared'),
        ];
        await pumpEventQueue();
        await drain(pending);

        expect(served, ['blocker', 'shared', 'preload']);
      },
    );

    test('a cancelled queued request leaves the queue', () async {
      final cancel = CancelToken();
      final blocking = get('blocker');
      final cancelled = client.getBytes(
        url('gone'),
        cancelToken: cancel,
        priority: PriorityToken(RequestPriority.visible),
      );
      final pending = [blocking, get('later', RequestPriority.background)];
      await pumpEventQueue();
      cancel.cancel();
      await expectLater(
        cancelled,
        throwsA(isA<HttpBytesException$Cancelled>()),
      );
      await drain(pending);

      expect(served, ['blocker', 'later']);
    });

    test('the resolver forwards the request priority', () async {
      final resolver = BytesResolver(cache: MemoryBytesCache(), client: client);
      final pending = [
        get('blocker'),
        resolver.resolve(
          BytesRequest(
            url: url('preload').toString(),
            priority: PriorityToken(RequestPriority.preload),
          ),
        ),
        resolver.resolve(BytesRequest(url: url('visible').toString())),
      ];
      await pumpEventQueue();
      await drain(pending);

      expect(served, ['blocker', 'visible', 'preload']);
    });
  });
}
