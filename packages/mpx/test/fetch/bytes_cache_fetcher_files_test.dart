import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx/mpx.dart';
import 'package:mpx/testing.dart';
import 'package:mpx_core/mpx_core.dart';

/// The fetcher over a store that keeps files: content goes out as the file
/// it is in, or as a ranged resource read natively, never as bytes.
void main() {
  final clip = Uint8List.fromList([for (var i = 0; i < 5000; i++) i % 251]);
  const video = MediaDescriptor(
    key: MediaKey.remote('clip/1'),
    kind: MediaKind.video,
  );
  const still = MediaDescriptor(
    key: MediaKey.remote('still/1'),
    kind: MediaKind.still,
  );

  late Directory dir;
  late IRangedBytesStore store;
  late HttpBytesClient client;
  late RangedBytes ranged;
  late List<String> requested;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('mpx_fetcher_files_');
    store =
        await BytesCache.open(directory: dir.path, throwOnOpenFailure: true)
            as IRangedBytesStore;
    requested = [];
    client = HttpBytesClient(
      client: MockClient.streaming((request, _) async {
        requested.add('${request.url.path} ${request.headers['range']}');
        return http.StreamedResponse(
          Stream.fromIterable([clip.sublist(0, 2000), clip.sublist(2000)]),
          200,
          contentLength: clip.length,
          headers: {'accept-ranges': 'bytes'},
        );
      }),
    );
    ranged = RangedBytes(store: store, client: client);
  });

  tearDown(() async {
    await ranged.close();
    await client.close();
    await store.close();
    dir.deleteSync(recursive: true);
  });

  BytesCacheFetcher fetcher({RangedContentPublisher? publisher}) =>
      BytesCacheFetcher(
        store: store,
        client: client,
        ranged: ranged,
        publisher: publisher,
        locate: (descriptor, part) =>
            MediaLocation('https://cdn.test/${descriptor.key.encoded}'),
      );

  FetchRequest request(
    MediaDescriptor descriptor, {
    FetchProgress? onProgress,
  }) => FetchRequest(
    descriptor: descriptor,
    part: FetchPart.content,
    priority: AssetPriority.visible,
    cancellation: CancellationToken(),
    onProgress: onProgress ?? (_, _) {},
  );

  BytesCacheKey keyOf(MediaDescriptor descriptor) =>
      BytesCacheFetcher.cacheKeyOf(descriptor.key, FetchPart.content);

  test('a held part goes out as its file, kept until released', () async {
    await store.write(keyOf(still), clip);

    final content = await fetcher().fetch(request(still));

    final path = (content as FetchedFile).path;
    expect(File(path).readAsBytesSync(), clip);
    expect(requested, isEmpty);
    // Evicted while the decoder reads it: the file stays until released.
    await store.evict(keyOf(still));
    expect(File(path).existsSync(), isTrue);
    content.release();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(File(path).existsSync(), isFalse);
  });

  test('a missing part smaller than a part is fetched into the store in one '
      'GET and goes out as its file', () async {
    final reports = <(int, int?)>[];

    final content = await fetcher().fetch(
      request(
        still,
        onProgress: (received, total) {
          reports.add((received, total));
        },
      ),
    );

    // The first part asks for 512 KiB; the server sends the 5000 there are.
    expect(requested, ['/${still.key.encoded} bytes=0-524287']);
    expect(File((content as FetchedFile).path).readAsBytesSync(), clip);
    expect(store.contains(keyOf(still)), isTrue);
    expect(reports.last, (clip.length, clip.length));
    content.release();
  });

  test(
    'a missing part of a published kind is published, not downloaded',
    () async {
      final publisher = FakeRangedContentPublisher(kinds: {MediaKind.video});

      final content = await fetcher(publisher: publisher).fetch(request(video));

      expect(content, isA<FetchedRanged>());
      expect((content as FetchedRanged).key, keyOf(video).value);
      expect(publisher.published.single.cacheKey, keyOf(video));
      expect(requested, isEmpty);
      content.release();
      expect(publisher.released, 1);
    },
  );

  test('a held part of a published kind goes out as its file', () async {
    final publisher = FakeRangedContentPublisher(kinds: {MediaKind.video});
    await store.write(keyOf(video), clip);

    final content = await fetcher(publisher: publisher).fetch(request(video));

    expect(content, isA<FetchedFile>());
    expect(publisher.published, isEmpty);
    content.release();
  });

  test('a kind the publisher does not take is fetched whole', () async {
    final publisher = FakeRangedContentPublisher(kinds: {MediaKind.video});

    final content = await fetcher(publisher: publisher).fetch(request(still));

    expect(content, isA<FetchedFile>());
    expect(publisher.published, isEmpty);
    content.release();
  });
}
