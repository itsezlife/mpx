import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx_capture/mpx_capture.dart';
import 'package:mpx_capture/testing.dart';
import 'package:mpx_core/mpx_core.dart';

const _uuid = '3f1c2a7e-9b4d-4c1e-8a2f-0d5e6b7c8a91';

void main() {
  late Directory temp;
  late FakeTranscoder transcoder;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('mpx_capture_cache_');
    transcoder = FakeTranscoder(
      sources: {
        '/picked.mp4': const SourceVideo(
          dimensions: MediaDimensions(1920, 1080),
          duration: Duration(seconds: 4),
          codec: SourceCodec.h264,
          videoBitrate: 8000000,
        ),
      },
    );
  });
  tearDown(() => temp.deleteSync(recursive: true));

  Future<CaptureOutput> compress() => transcoder
      .compress(
        TranscodeRequest(
          sourcePath: '/picked.mp4',
          outputPath: '${temp.path}/out.mp4',
          preset: CompressionPreset.medium,
        ),
      )
      .output;

  group('CaptureCache keys', () {
    test('mints a local media key per capture', () {
      final cache = CaptureCache(store: MemoryBytesCache());
      final a = cache.mintKey();
      final b = cache.mintKey();
      expect(a, isA<MediaKey$Local>());
      expect(a, isNot(b));
      expect(
        a.encoded,
        matches(
          RegExp(
            '^local-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-'
            '[0-9a-f]{12}'
            r'$',
          ),
        ),
        reason: 'a version 4 UUID',
      );
    });

    test('takes its UUIDs from the given source', () {
      final cache = CaptureCache(
        store: MemoryBytesCache(),
        newUuid: () => _uuid,
      );
      expect(cache.mintKey(), MediaKey.local(_uuid));
    });

    test('the cache key is the local key in the fetcher\'s content form', () {
      expect(
        CaptureCache.cacheKeyOf(MediaKey$Local(_uuid)),
        const BytesCacheKey('local-$_uuid'),
      );
    });
  });

  for (final (name, open) in <(String, Future<IBytesStore> Function())>[
    (
      'disk store',
      () => BytesCache.open(
        directory: Directory('${temp.path}/store').path,
        throwOnOpenFailure: true,
      ),
    ),
    ('memory store', () async => MemoryBytesCache()),
  ]) {
    group('CaptureCache over a $name', () {
      late IBytesStore store;
      late CaptureCache cache;

      setUp(() async {
        Directory('${temp.path}/store').createSync();
        store = await open();
        cache = CaptureCache(store: store);
      });
      tearDown(() => store.close());

      test('the output resolves under its local key at once', () async {
        final key = cache.mintKey();
        final output = await compress();
        final bytes = File(output.path).readAsBytesSync();

        await cache.put(key, output);

        final local = CaptureCache.cacheKeyOf(key);
        expect(store.contains(local), isTrue);
        expect(await store.read(local), bytes);
        expect(File(output.path).existsSync(), isFalse, reason: 'moved in');
      });

      test('keeping the source file is the caller\'s choice', () async {
        final key = cache.mintKey();
        final output = await compress();
        await cache.put(key, output, deleteSource: false);
        expect(File(output.path).existsSync(), isTrue);
      });

      test('the server key resolves to the same bytes after upload', () async {
        final key = cache.mintKey();
        final output = await compress();
        final bytes = File(output.path).readAsBytesSync();
        await cache.put(key, output);

        const server = BytesCacheKey('remote-5368');
        expect(await cache.alias(key, server), isTrue);
        expect(await store.read(server), bytes);
        expect(await store.read(CaptureCache.cacheKeyOf(key)), bytes);
      });

      test('confirming the message releases the local key only', () async {
        final key = cache.mintKey();
        final output = await compress();
        final bytes = File(output.path).readAsBytesSync();
        await cache.put(key, output);
        const server = BytesCacheKey('remote-5368');
        await cache.alias(key, server);

        await cache.release(key);

        expect(store.contains(CaptureCache.cacheKeyOf(key)), isFalse);
        expect(await store.read(CaptureCache.cacheKeyOf(key)), isNull);
        expect(await store.read(server), bytes);
      });

      test('nothing to alias before the output is in', () async {
        final key = cache.mintKey();
        expect(
          await cache.alias(key, const BytesCacheKey('remote-1')),
          isFalse,
        );
      });
    });
  }

  test('the disk store hands out the file for a player', () async {
    Directory('${temp.path}/store').createSync();
    final store = await BytesCache.open(
      directory: '${temp.path}/store',
      throwOnOpenFailure: true,
    );
    addTearDown(store.close);
    final cache = CaptureCache(store: store);
    final key = cache.mintKey();
    final output = await compress();
    final bytes = Uint8List.fromList(File(output.path).readAsBytesSync());
    await cache.put(key, output);

    final lease = await store.leaseFile(CaptureCache.cacheKeyOf(key));
    expect(lease, isNotNull);
    addTearDown(lease!.release);
    expect(File(lease.path).readAsBytesSync(), bytes);
  });

  test('a large output moves into a disk store in pieces', () async {
    Directory('${temp.path}/store').createSync();
    final store =
        await BytesCache.open(
              directory: '${temp.path}/store',
              throwOnOpenFailure: true,
            )
            as IRangedBytesStore;
    addTearDown(store.close);
    final cache = CaptureCache(store: store);
    final key = cache.mintKey();
    // Two and a half of the store's one-megabyte pieces.
    final bytes = Uint8List.fromList(
      List<int>.generate(5 << 19, (i) => i * 7 & 0xff),
    );
    final path = '${temp.path}/big.mp4';
    File(path).writeAsBytesSync(bytes);

    await cache.put(
      key,
      CaptureOutput(
        path: path,
        size: bytes.length,
        duration: const Duration(seconds: 30),
        dimensions: const MediaDimensions(384, 384),
        headerRewritten: true,
      ),
    );

    final state = store.rangesOf(CaptureCache.cacheKeyOf(key));
    expect(state?.isComplete, isTrue);
    expect(state?.totalLength, bytes.length);
    expect(await store.read(CaptureCache.cacheKeyOf(key)), bytes);
  });
}
