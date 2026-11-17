import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_video_decoder/src/binding/binding.dart';

// ignore: always_use_package_imports
import 'support/fixtures.dart';
// ignore: always_use_package_imports
import 'support/mp4_layout.dart';
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

      test('opens without waiting: stalled until its length is told', () {
        final key = freshKey();
        table!.publish(key, mp4.path, landed: 0, lengthKnown: false);
        final source = VideoSource.ranged(readerApi: table.api, key: key);

        // On this isolate: nothing blocks, so nothing else has to land it.
        final before = binding.open(source, width: 32, height: 24);
        table.land(key, File(mp4.path).lengthSync());
        final after = binding.open(source, width: 32, height: 24);

        expect((before as VideoRejected).reason, VideoRejection.stalled);
        expect(after, isA<VideoOpened>());
        expect(table.waitsOf(key), 0);
        binding.dispose((after as VideoOpened).handle);
      });

      for (final lookahead in [4096, 1]) {
        test(
          'a clip that runs out of bytes stalls and goes on with the '
          'next frame, none skipped and none twice (lookahead $lookahead)',
          () {
            final key = freshKey();
            final length = File(mp4.path).lengthSync();
            // The index and a little of the media data.
            final (_, moovEnd) = boxSpan(mp4.bytes, 'moov');
            table!.publish(key, mp4.path, landed: moovEnd + 2000);
            final source = VideoSource.ranged(
              readerApi: table.api,
              key: key,
              lookaheadBytes: lookahead,
            );

            final frames = <(int, int)>[];
            var stalls = 0;
            var landed = moovEnd + 2000;
            // Probing the stream reads its first packets: the open stalls
            // until they are there, then opens long before the end.
            var opened = binding.open(source, width: 32, height: 24);
            while (opened is VideoRejected &&
                opened.reason == VideoRejection.stalled) {
              landed = math.min(landed + 3000, length);
              table.land(key, landed);
              opened = binding.open(source, width: 32, height: 24);
            }
            // ignore: avoid_print
            print('opened with $landed of $length bytes');
            expect(landed, lessThan(length));
            final handle = (opened as VideoOpened).handle;
            final target = calloc<Uint8>(32 * 24 * 4);
            addTearDown(() {
              calloc.free(target);
              binding.dispose(handle);
            });
            while (true) {
              final result = binding.nextFrame(
                handle,
                target: target,
                strideBytes: 32 * 4,
              );
              if (result.status == VideoFrameStatus.stalled) {
                stalls++;
                landed = math.min(landed + 3000, length);
                table.land(key, landed);
                continue;
              }
              if (result.status != VideoFrameStatus.frame) {
                expect(result.status, VideoFrameStatus.endOfStream);
                break;
              }
              frames.add((
                result.ptsMs,
                _hash(target.asTypedList(32 * 24 * 4)),
              ));
            }

            expect(stalls, greaterThan(3));
            expect(frames, _decodeAll(binding, VideoSource.file(mp4.path)));
            expect(table.waitsOf(key), 0, reason: 'no read ever waited');
          },
        );
      }

      test('with its moov after the media data, opens once the head and '
          'the tail are there, not the middle', () {
        final key = freshKey();
        final file = File('${Directory.systemTemp.path}/moov-at-end-$pid.mp4')
          ..writeAsBytesSync(moovAtEnd(mp4.bytes));
        addTearDown(file.deleteSync);
        final bytes = file.readAsBytesSync();
        final (moovStart, moovEnd) = boxSpan(bytes, 'moov');
        table!.publish(key, file.path, landed: 4096);
        final source = VideoSource.ranged(
          readerApi: table.api,
          key: key,
          lookaheadBytes: 1,
        );

        final headOnly = binding.open(source, width: 32, height: 24);
        table.landSpan(key, moovStart, moovEnd);
        // The index is there; probing wants the first packets of the media
        // data, from the head on.
        var landed = 4096;
        var opened = binding.open(source, width: 32, height: 24);
        while (opened is VideoRejected &&
            opened.reason == VideoRejection.stalled) {
          landed += 3000;
          table.land(key, landed);
          opened = binding.open(source, width: 32, height: 24);
        }

        expect((headOnly as VideoRejected).reason, VideoRejection.stalled);
        expect(opened, isA<VideoOpened>());
        final target = calloc<Uint8>(32 * 24 * 4);
        addTearDown(() => calloc.free(target));
        final handle = (opened as VideoOpened).handle;
        addTearDown(() => binding.dispose(handle));
        var first = binding.nextFrame(
          handle,
          target: target,
          strideBytes: 32 * 4,
        );
        while (first.status == VideoFrameStatus.stalled) {
          landed += 3000;
          table.land(key, landed);
          first = binding.nextFrame(
            handle,
            target: target,
            strideBytes: 32 * 4,
          );
        }
        expect(first.status, VideoFrameStatus.frame);
        expect(landed, lessThan(moovStart));
      });

      test('that is withdrawn fails as a source, at once', () {
        final key = freshKey();
        table!.publish(key, mp4.path);
        final opened =
            binding.open(
                  VideoSource.ranged(readerApi: table.api, key: key),
                  width: 32,
                  height: 24,
                )
                as VideoOpened;
        addTearDown(() => binding.dispose(opened.handle));
        final target = calloc<Uint8>(32 * 24 * 4);
        addTearDown(() => calloc.free(target));

        table.withdraw(key);
        final result = binding.nextFrame(
          opened.handle,
          target: target,
          strideBytes: 32 * 4,
        );

        expect(result.status, VideoFrameStatus.failed);
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
