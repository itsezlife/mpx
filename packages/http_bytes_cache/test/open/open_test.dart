import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http_bytes_cache/src/bytes_cache.dart';
import 'package:http_bytes_cache/src/bytes_diagnostics.dart';
import 'package:http_bytes_cache/src/environment_specific/blob_store_file_vm.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('http_bytes_cache_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('BytesCache.open (VM)', () {
    test('close then reopen returns committed bytes and meta', () async {
      const key = BytesCacheKey('logo');
      final bytes = Uint8List.fromList([1, 2, 3, 4]);

      final first = await BytesCache.open(
        directory: tempDir.path,
        retention: const BytesRetention.unlimited(),
      );
      await first.write(key, bytes);
      await first.close();

      final second = await BytesCache.open(
        directory: tempDir.path,
        retention: const BytesRetention.unlimited(),
      );
      addTearDown(second.close);

      expect(await second.read(key), bytes);
    });

    test('multi-key mutate epoch survives close/reopen', () async {
      var now = DateTime.utc(2024, 1, 1);
      final first = await BytesCache.open(
        directory: tempDir.path,
        retention: const BytesRetention.maxEntries(2),
        clock: () => now,
      );

      await first.write(const BytesCacheKey('a'), Uint8List.fromList([1]));
      now = now.add(const Duration(seconds: 1));
      await first.write(const BytesCacheKey('b'), Uint8List.fromList([2]));
      now = now.add(const Duration(seconds: 1));
      await first.read(const BytesCacheKey('a'));
      now = now.add(const Duration(seconds: 1));
      // Soft-LRU flush + put c + delete b in one exclusive epoch / one commit.
      await first.write(const BytesCacheKey('c'), Uint8List.fromList([3]));
      await first.close();

      final second = await BytesCache.open(
        directory: tempDir.path,
        retention: const BytesRetention.maxEntries(2),
        clock: () => now,
      );
      addTearDown(second.close);

      expect(
        await second.read(const BytesCacheKey('a')),
        Uint8List.fromList([1]),
      );
      expect(await second.read(const BytesCacheKey('b')), isNull);
      expect(
        await second.read(const BytesCacheKey('c')),
        Uint8List.fromList([3]),
      );
      expect(
        File(
          p.join(tempDir.path, BytesBlobStore$File$VM.indexFileName),
        ).existsSync(),
        isTrue,
      );
    });

    test('large write round-trips after close/reopen', () async {
      const key = BytesCacheKey('raster');
      final bytes = Uint8List(96 * 1024);
      for (var i = 0; i < bytes.length; i++) {
        bytes[i] = i & 0xff;
      }

      final first = await BytesCache.open(
        directory: tempDir.path,
        retention: const BytesRetention.unlimited(),
      );
      await first.write(key, bytes);
      await first.close();

      final second = await BytesCache.open(
        directory: tempDir.path,
        retention: const BytesRetention.unlimited(),
      );
      addTearDown(second.close);

      expect(await second.read(key), bytes);
    });

    test('open failure degrades to memory and reports a warning', () async {
      final blocker = File(p.join(tempDir.path, 'not_a_directory'))
        ..writeAsBytesSync([1]);
      final events = <BytesLogEvent>[];

      final cache = await BytesCache.open(
        directory: p.join(blocker.path, 'nested'),
        retention: const BytesRetention.unlimited(),
        diagnostics: BytesDiagnostics.onEvent(events.add),
      );
      addTearDown(cache.close);

      expect(cache, isA<MemoryBytesCache>());
      expect(events, hasLength(1));
      expect(events.single.level, BytesLogLevel.warning);
      expect(events.single.op, BytesLogOp.openDegraded);

      const key = BytesCacheKey('in_memory');
      final bytes = Uint8List.fromList([9]);
      await cache.write(key, bytes);
      expect(await cache.read(key), bytes);
    });

    test('open failure degrade closes the partial VM worker', () async {
      BytesBlobStore$File$VM.debugActiveWorkerCount = 0;
      final blocker = File(p.join(tempDir.path, 'not_a_directory'))
        ..writeAsBytesSync([1]);

      final cache = await BytesCache.open(
        directory: p.join(blocker.path, 'nested'),
        retention: const BytesRetention.unlimited(),
      );
      addTearDown(cache.close);

      expect(cache, isA<MemoryBytesCache>());
      expect(
        BytesBlobStore$File$VM.debugActiveWorkerCount,
        0,
        reason: 'degrade must close the worker spawned before mkdir failed',
      );
    });

    test('open failure throws when throwOnOpenFailure is true', () async {
      final blocker = File(p.join(tempDir.path, 'not_a_directory'))
        ..writeAsBytesSync([1]);

      await expectLater(
        BytesCache.open(
          directory: p.join(blocker.path, 'nested'),
          throwOnOpenFailure: true,
        ),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('throwOnOpenFailure also closes the partial VM worker', () async {
      BytesBlobStore$File$VM.debugActiveWorkerCount = 0;
      final blocker = File(p.join(tempDir.path, 'not_a_directory'))
        ..writeAsBytesSync([1]);

      await expectLater(
        BytesCache.open(
          directory: p.join(blocker.path, 'nested'),
          throwOnOpenFailure: true,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        BytesBlobStore$File$VM.debugActiveWorkerCount,
        0,
        reason: 'strict open must not leave a live worker behind on failure',
      );
    });

    test(
      'missing VM directory throws ArgumentError without degrading',
      () async {
        BytesBlobStore$File$VM.debugActiveWorkerCount = 0;

        await expectLater(
          BytesCache.open(directory: null),
          throwsA(isA<ArgumentError>()),
        );
        await expectLater(
          BytesCache.open(directory: ''),
          throwsA(isA<ArgumentError>()),
        );
        expect(
          BytesBlobStore$File$VM.debugActiveWorkerCount,
          0,
          reason: 'host wiring ArgumentError must not spawn or leak a worker',
        );
      },
    );

    test('soft LRU: capacity trim after read flush on write', () async {
      var now = DateTime.utc(2024, 1, 1);
      final cache = await BytesCache.open(
        directory: tempDir.path,
        retention: const BytesRetention.maxEntries(2),
        clock: () => now,
      );
      addTearDown(cache.close);

      await cache.write(const BytesCacheKey('a'), Uint8List.fromList([1]));
      now = now.add(const Duration(seconds: 1));
      await cache.write(const BytesCacheKey('b'), Uint8List.fromList([2]));
      now = now.add(const Duration(seconds: 1));
      await cache.read(const BytesCacheKey('a'));
      now = now.add(const Duration(seconds: 1));
      await cache.write(const BytesCacheKey('c'), Uint8List.fromList([3]));

      expect(
        await cache.read(const BytesCacheKey('a')),
        Uint8List.fromList([1]),
      );
      expect(await cache.read(const BytesCacheKey('b')), isNull);
      expect(
        await cache.read(const BytesCacheKey('c')),
        Uint8List.fromList([3]),
      );
    });

    test('orphan blob without index is reclaimed on open', () async {
      File(p.join(tempDir.path, 'orphan')).writeAsBytesSync([1, 2, 3]);

      final cache = await BytesCache.open(
        directory: tempDir.path,
        retention: const BytesRetention.unlimited(),
      );
      addTearDown(cache.close);

      expect(File(p.join(tempDir.path, 'orphan')).existsSync(), isFalse);
      expect(await cache.read(const BytesCacheKey('orphan')), isNull);
    });

    test('orphan blob without index is reclaimed on prune', () async {
      final cache = await BytesCache.open(
        directory: tempDir.path,
        retention: const BytesRetention.unlimited(),
      );
      addTearDown(cache.close);

      await cache.write(const BytesCacheKey('kept'), Uint8List.fromList([4]));
      File(p.join(tempDir.path, 'stray')).writeAsBytesSync([5, 6]);

      await cache.prune();

      expect(File(p.join(tempDir.path, 'stray')).existsSync(), isFalse);
      expect(
        await cache.read(const BytesCacheKey('kept')),
        Uint8List.fromList([4]),
      );
    });

    test('temp-only blob file is not a cache hit', () async {
      File(p.join(tempDir.path, 'logo.tmp')).writeAsBytesSync([1, 2, 3]);

      final cache = await BytesCache.open(
        directory: tempDir.path,
        retention: const BytesRetention.unlimited(),
      );
      addTearDown(cache.close);

      expect(await cache.read(const BytesCacheKey('logo')), isNull);
    });

    test('corrupt index recovers by wiping without crash-looping', () async {
      File(
        p.join(tempDir.path, BytesBlobStore$File$VM.indexFileName),
      ).writeAsBytesSync(
        const Utf8Encoder().convert('not-json'),
      );
      File(p.join(tempDir.path, 'stale')).writeAsBytesSync([9]);

      final cache = await BytesCache.open(
        directory: tempDir.path,
        retention: const BytesRetention.unlimited(),
      );
      addTearDown(cache.close);

      expect(await cache.read(const BytesCacheKey('stale')), isNull);
      expect(File(p.join(tempDir.path, 'stale')).existsSync(), isFalse);

      const key = BytesCacheKey('fresh');
      final bytes = Uint8List.fromList([1, 2]);
      await cache.write(key, bytes);
      expect(await cache.read(key), bytes);
    });

    test('unrecognized index version recovers by wiping', () async {
      File(
        p.join(tempDir.path, BytesBlobStore$File$VM.indexFileName),
      ).writeAsBytesSync(
        const JsonEncoder().fuse(const Utf8Encoder()).convert({
          'v': 99,
          'e': {
            'old': {'w': 1, 'a': 1, 'n': 1},
          },
        }),
      );
      File(p.join(tempDir.path, 'old')).writeAsBytesSync([7]);

      final cache = await BytesCache.open(
        directory: tempDir.path,
        retention: const BytesRetention.unlimited(),
      );
      addTearDown(cache.close);

      expect(await cache.read(const BytesCacheKey('old')), isNull);
      expect(File(p.join(tempDir.path, 'old')).existsSync(), isFalse);
    });

    test('close is idempotent and rejects later ops', () async {
      final cache = await BytesCache.open(
        directory: tempDir.path,
        retention: const BytesRetention.unlimited(),
      );
      await cache.write(const BytesCacheKey('a'), Uint8List.fromList([1]));
      await cache.close();
      await cache.close();

      await expectLater(
        cache.read(const BytesCacheKey('a')),
        throwsA(isA<StateError>()),
      );
    });
  });
}
