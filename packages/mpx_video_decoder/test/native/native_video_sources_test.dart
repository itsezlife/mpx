import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_video_decoder/src/binding/binding.dart';

// ignore: always_use_package_imports
import 'support/fixtures.dart';
// ignore: always_use_package_imports
import 'support/ranged_reader_table.dart';

/// Opening a clip from a file or through a ranged reader: the bytes are read
/// where they are, at the offsets the demuxer asks for.
void main() {
  final binding = NativeVideoBinding.probe();
  final table = RangedReaderTable.compile();
  var keys = 0;
  String freshKey() => 'clip-${keys++}-$pid';

  group('a file source', skip: nativeSkipReason(binding), () {
    test('decodes the frames its bytes decode', () {
      for (final fixture in fixtures) {
        final fromBytes = _decodeAll(binding, VideoSource.bytes(fixture.bytes));
        final fromFile = _decodeAll(binding, VideoSource.file(fixture.path));

        expect(fromFile, fromBytes, reason: fixture.file);
        expect(fromFile, hasLength(fixture.frames), reason: fixture.file);
      }
    });

    test('larger than the in-memory cap opens, read in place', () {
      // The cap bounds a copy held in memory; a file read at offsets holds
      // none. A real clip with padding after it is over the cap.
      final file = File('${Directory.systemTemp.path}/large-clip-$pid.webm')
        ..writeAsBytesSync([...webm.bytes, ...Uint8List(11 * 1024 * 1024)]);
      addTearDown(file.deleteSync);

      final fromFile = _decodeAll(binding, VideoSource.file(file.path));

      expect(fromFile, hasLength(webm.frames));
      expect(
        binding.open(
          VideoSource.bytes(file.readAsBytesSync()),
          width: 32,
          height: 24,
        ),
        isA<VideoRejected>().having(
          (r) => r.reason,
          'reason',
          VideoRejection.tooLarge,
        ),
      );
    });

    test('that does not exist is rejected as an unreadable source', () {
      final result = binding.open(
        VideoSource.file('${Directory.systemTemp.path}/no-such-clip.mp4'),
        width: 32,
        height: 24,
      );

      expect(result, isA<VideoRejected>());
      expect((result as VideoRejected).reason, VideoRejection.source);
    });

    test('that is not a video is malformed', () {
      final file = File('${Directory.systemTemp.path}/not-a-clip-$pid.mp4')
        ..writeAsBytesSync(List.filled(4096, 7));
      addTearDown(file.deleteSync);

      final result = binding.open(
        VideoSource.file(file.path),
        width: 32,
        height: 24,
      );

      expect((result as VideoRejected).reason, VideoRejection.malformed);
    });
  });

  group(
    'a ranged source',
    skip: nativeSkipReason(binding) ?? (table == null ? 'no cc' : null),
    () {
      test('with every byte landed decodes the frames its file decodes', () {
        for (final fixture in fixtures) {
          final key = freshKey();
          table!.publish(key, fixture.path);

          final fromReader = _decodeAll(
            binding,
            VideoSource.ranged(readerApi: table.api, key: key),
          );

          expect(
            fromReader,
            _decodeAll(binding, VideoSource.file(fixture.path)),
            reason: fixture.file,
          );
          expect(table.waitsOf(key), 0, reason: fixture.file);
          expect(table.openReadersOf(key), 0, reason: 'closed on dispose');
        }
      });

      test('waits for the bytes it reads, and opens once they land', () async {
        final key = freshKey();
        table!.publish(key, webm.path, landed: 0, lengthKnown: false);

        var done = false;
        final opened = _openOnWorker(table, key);
        unawaited(opened.whenComplete(() => done = true));
        await _until(() => table.waitsOf(key) == 1);
        // Blocked on the length. Half the file lands: the reads go on until
        // they pass it, and wait there.
        final length = File(webm.path).lengthSync();
        table.land(key, length ~/ 2);
        await _until(() => table.waitsOf(key) == 2);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(done, isFalse);

        table.land(key, length);

        expect(await opened, (status: 'opened', frames: webm.frames));
      });

      test('that is withdrawn while a read waits fails as a source', () async {
        final key = freshKey();
        table!.publish(key, mp4.path, landed: 1024);

        final opened = _openOnWorker(table, key);
        await _until(() => table.waitsOf(key) > 0);
        table.withdraw(key);

        expect(await opened, (status: 'source', frames: 0));
        expect(table.openReadersOf(key), 0);
      });

      test('that is not published is rejected as a source', () {
        final result = binding.open(
          VideoSource.ranged(readerApi: table!.api, key: 'never-published'),
          width: 32,
          height: 24,
        );

        expect((result as VideoRejected).reason, VideoRejection.source);
      });

      test('over a table of another version is a wiring error', () {
        final key = freshKey();
        table!.publish(key, mp4.path);

        expect(
          () => binding.open(
            VideoSource.ranged(readerApi: table.oldApi, key: key),
            width: 32,
            height: 24,
          ),
          throwsArgumentError,
        );
        expect(table.opensOf(key), 0);
      });
    },
  );
}

/// Opens [key] of [table] on another isolate, as the decode worker does
/// (the reads block that isolate), and decodes every frame there.
Future<({String status, int frames})> _openOnWorker(
  RangedReaderTable table,
  String key,
) {
  final library = table.libraryPath;
  return Isolate.run(() {
    final api = RangedReaderTable.at(library).api;
    final binding = NativeVideoBinding.probe();
    final result = binding.open(
      VideoSource.ranged(readerApi: api, key: key),
      width: 32,
      height: 24,
    );
    return switch (result) {
      VideoRejected(:final reason) => (status: reason.name, frames: 0),
      VideoOpened() => (
        status: 'opened',
        frames: _countFrames(binding, result.handle),
      ),
    };
  });
}

int _countFrames(VideoBinding binding, VideoHandle handle) {
  final target = calloc<Uint8>(32 * 24 * 4);
  try {
    var frames = 0;
    while (binding
            .nextFrame(handle, target: target, strideBytes: 32 * 4)
            .status ==
        VideoFrameStatus.frame) {
      frames++;
    }
    return frames;
  } finally {
    calloc.free(target);
    binding.dispose(handle);
  }
}

Future<void> _until(bool Function() condition) async {
  final clock = Stopwatch()..start();
  while (!condition()) {
    if (clock.elapsed > const Duration(seconds: 10)) {
      fail('the condition did not hold within 10 seconds');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

/// Every frame of [source] at 32 x 24, as its time and a hash of its pixels.
List<(int, int)> _decodeAll(VideoBinding binding, VideoSource source) {
  final opened = binding.open(source, width: 32, height: 24) as VideoOpened;
  final target = calloc<Uint8>(32 * 24 * 4);
  try {
    final frames = <(int, int)>[];
    while (true) {
      final result = binding.nextFrame(
        opened.handle,
        target: target,
        strideBytes: 32 * 4,
      );
      if (result.status != VideoFrameStatus.frame) {
        expect(result.status, VideoFrameStatus.endOfStream);
        return frames;
      }
      frames.add((result.ptsMs, _hash(target.asTypedList(32 * 24 * 4))));
    }
  } finally {
    calloc.free(target);
    binding.dispose(opened.handle);
  }
}

int _hash(Uint8List bytes) {
  var hash = 0x811c9dc5;
  for (final byte in bytes) {
    hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
  }
  return hash;
}
