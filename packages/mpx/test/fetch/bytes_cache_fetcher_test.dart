import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx/mpx.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';

// A network of a few files, which can go offline and answers what the test
// sets per path.
final class _Origin {
  final Map<String, Uint8List> files = {};
  final Map<String, int> statuses = {};
  final List<String> requested = [];
  bool online = true;
  Completer<void>? gate;

  late final http.Client client = MockClient.streaming((request, _) async {
    final path = request.url.path;
    requested.add(path);
    if (!online) throw const SocketException('offline');
    await gate?.future;
    if (statuses[path] case final status?) {
      return http.StreamedResponse(const Stream.empty(), status);
    }
    final body = files[path];
    if (body == null) return http.StreamedResponse(const Stream.empty(), 404);
    return http.StreamedResponse(
      Stream.fromIterable([body.sublist(0, 2), body.sublist(2)]),
      200,
      contentLength: body.length,
    );
  });
}

final Uint8List _clip = Uint8List.fromList([1, 2, 3, 4, 5]);
final Uint8List _still = Uint8List.fromList([9, 8, 7]);

const MediaKey _available = MediaKey.remote('clip/1');
const MediaKey _missing = MediaKey.remote('clip/2');
const MediaKey _unlocated = MediaKey.external('nowhere');

const MediaDescriptor _availableDescriptor = MediaDescriptor(
  key: _available,
  kind: MediaKind.video,
  thumbnail: MediaThumbnailRef('still-1'),
);

// Locates `remote` keys under /media/<id> and their thumbnails under
// /thumbnails/<ref>; nothing else.
MediaLocation? _locate(MediaDescriptor descriptor, FetchPart part) =>
    switch ((descriptor.key, part)) {
      (MediaKey$Remote(:final id), FetchPart.content) => MediaLocation(
        'https://cdn.test/media/$id',
      ),
      (MediaKey$Remote(), FetchPart.thumbnail) => MediaLocation(
        'https://cdn.test/thumbnails/${descriptor.thumbnail!.value}',
      ),
      _ => null,
    };

void main() {
  late _Origin origin;
  late MemoryBytesCache store;
  late HttpBytesClient client;
  late List<(MediaDescriptor, FetchPart)> located;

  BytesCacheFetcher fetcherOver({MediaLocator? locate}) => BytesCacheFetcher(
    store: store,
    client: client,
    locate:
        locate ??
        (descriptor, part) {
          located.add((descriptor, part));
          return _locate(descriptor, part);
        },
  );

  setUp(() {
    origin = _Origin()
      ..files['/media/clip/1'] = _clip
      ..files['/thumbnails/still-1'] = _still;
    store = MemoryBytesCache();
    client = HttpBytesClient(client: origin.client);
    located = [];
  });

  tearDown(() => client.close());

  FetchRequest request(
    MediaDescriptor descriptor, {
    FetchPart part = FetchPart.content,
    CancellationToken? cancellation,
    FetchProgress? onProgress,
  }) => FetchRequest(
    descriptor: descriptor,
    part: part,
    priority: AssetPriority.visible,
    cancellation: cancellation ?? CancellationToken(),
    onProgress: onProgress ?? (_, _) {},
  );

  Future<FetchFailure> failureOf(Future<FetchedContent> fetch) async {
    try {
      await fetch;
    } on FetchFailure catch (failure) {
      return failure;
    }
    fail('expected a FetchFailure');
  }

  AssetFetcherContract.run(() {
    origin = _Origin()
      ..files['/media/clip/1'] = _clip
      ..files['/thumbnails/still-1'] = _still;
    store = MemoryBytesCache();
    client = HttpBytesClient(client: origin.client);
    return AssetFetcherHarness(
      fetcher: fetcherOver(locate: _locate),
      available: _availableDescriptor,
      missing: const MediaDescriptor(key: _missing),
      goOffline: () => origin.online = false,
      goOnline: () => origin.online = true,
    );
  });

  group('cache keys', () {
    test('a content key is the media key in its stable form', () {
      expect(
        BytesCacheFetcher.cacheKeyOf(_available, FetchPart.content),
        BytesCacheKey(_available.encoded),
      );
    });

    test('a thumbnail key is apart from every content key', () {
      final thumbnail = BytesCacheFetcher.cacheKeyOf(
        _available,
        FetchPart.thumbnail,
      );

      expect(thumbnail.value, 'thumbnail-${_available.encoded}');
      expect(MediaKey.tryParse(thumbnail.value), isNull);
    });

    test('a long form is hashed to a short, stable key', () {
      final long = MediaKey.external('x' * 400);

      final key = BytesCacheFetcher.cacheKeyOf(long, FetchPart.content);

      expect(key.value.length, lessThanOrEqualTo(180));
      expect(key, BytesCacheFetcher.cacheKeyOf(long, FetchPart.content));
      expect(
        key,
        isNot(BytesCacheFetcher.cacheKeyOf(long, FetchPart.thumbnail)),
      );
    });
  });

  group('fetch', () {
    test('downloads the content and keeps it under its media key', () async {
      final content = await fetcherOver().fetch(request(_availableDescriptor));

      expect((content as FetchedBytes).bytes, _clip);
      expect(store.contains(BytesCacheKey(_available.encoded)), isTrue);
    });

    test('serves held content without locating it or a request', () async {
      final fetcher = fetcherOver();
      await fetcher.fetch(request(_availableDescriptor));
      located.clear();
      origin.requested.clear();

      final reports = <int>[];
      final content = await fetcher.fetch(
        request(
          _availableDescriptor,
          onProgress: (received, _) => reports.add(received),
        ),
      );

      expect((content as FetchedBytes).bytes, _clip);
      expect(located, isEmpty);
      expect(origin.requested, isEmpty);
      expect(reports, isEmpty, reason: 'a cached part is no transfer');
    });

    test('keeps the thumbnail apart from the content', () async {
      final fetcher = fetcherOver();

      final thumbnail = await fetcher.fetch(
        request(_availableDescriptor, part: FetchPart.thumbnail),
      );
      final content = await fetcher.fetch(request(_availableDescriptor));

      expect((thumbnail as FetchedBytes).bytes, _still);
      expect((content as FetchedBytes).bytes, _clip);
    });

    test('reports a download from 0 to its length', () async {
      final reports = <(int, int?)>[];

      await fetcherOver().fetch(
        request(
          _availableDescriptor,
          onProgress: (received, total) => reports.add((received, total)),
        ),
      );

      expect(reports.first, (0, 5));
      expect(reports.last, (5, 5));
    });

    test('a key the host cannot locate fails permanently', () async {
      final failure = await failureOf(
        fetcherOver().fetch(request(const MediaDescriptor(key: _unlocated))),
      );

      expect(failure.kind, AssetFailureKind.permanent);
    });

    test('a locator that throws fails the fetch transiently', () async {
      final fetcher = fetcherOver(
        locate: (_, _) => throw StateError('lookup failed'),
      );

      final failure = await failureOf(
        fetcher.fetch(request(_availableDescriptor)),
      );

      expect(failure.kind, AssetFailureKind.transient);
    });

    for (final (status, kind) in [
      (404, AssetFailureKind.permanent),
      (410, AssetFailureKind.permanent),
      (403, AssetFailureKind.permanent),
      (408, AssetFailureKind.transient),
      (429, AssetFailureKind.transient),
      (500, AssetFailureKind.transient),
      (503, AssetFailureKind.transient),
    ]) {
      test('HTTP $status fails ${kind.name}ly', () async {
        origin.statuses['/media/clip/1'] = status;

        final failure = await failureOf(
          fetcherOver().fetch(request(_availableDescriptor)),
        );

        expect(failure.kind, kind);
      });
    }

    test('a cancel settles at once while the download runs on', () async {
      origin.gate = Completer();
      final cancellation = CancellationToken();
      final fetcher = fetcherOver();
      final first = fetcher.fetch(
        request(_availableDescriptor, cancellation: cancellation),
      );
      final second = fetcher.fetch(request(_availableDescriptor));
      await pumpEventQueue();

      cancellation.cancel();
      final failure = await failureOf(first);
      origin.gate!.complete();

      expect(failure.kind, AssetFailureKind.transient);
      expect(((await second) as FetchedBytes).bytes, _clip);
      expect(origin.requested, hasLength(1));
    });

    test('media is never revalidated once held', () async {
      var now = DateTime.utc(2026);
      store = MemoryBytesCache(clock: () => now);
      final fetcher = fetcherOver();
      await fetcher.fetch(request(_availableDescriptor));
      origin.requested.clear();
      now = now.add(const Duration(days: 300));

      await fetcher.fetch(request(_availableDescriptor));

      expect(origin.requested, isEmpty);
    });
  });

  group('needsDownload', () {
    test('is true for content held nowhere', () {
      expect(fetcherOver().needsDownload(_available), isTrue);
    });

    test('is true while the content downloads', () async {
      origin.gate = Completer();
      final fetcher = fetcherOver();
      final fetch = fetcher.fetch(request(_availableDescriptor));
      await pumpEventQueue();

      expect(fetcher.needsDownload(_available), isTrue);

      origin.gate!.complete();
      await fetch;
    });

    test('is false once the content is held', () async {
      final fetcher = fetcherOver();
      await fetcher.fetch(request(_availableDescriptor));

      expect(fetcher.needsDownload(_available), isFalse);
    });

    test('ignores a held thumbnail', () async {
      final fetcher = fetcherOver();
      await fetcher.fetch(
        request(_availableDescriptor, part: FetchPart.thumbnail),
      );

      expect(fetcher.needsDownload(_available), isTrue);
    });
  });
}
