import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_video_decoder/src/binding/video_availability.dart';
import 'package:mpx_video_decoder/src/binding/video_binding.dart';
import 'package:mpx_video_decoder/src/binding/video_frame_result.dart';
import 'package:mpx_video_decoder/src/binding/video_handle.dart';
import 'package:mpx_video_decoder/src/binding/video_open_result.dart';
import 'package:mpx_video_decoder/src/binding/video_source.dart';

/// What a [VideoBindingContract] run needs besides the binding.
final class VideoBindingHarness {
  /// Creates a harness around [binding].
  VideoBindingHarness({
    required this.binding,
    required this.validBytes,
    required this.expectedInfo,
    required this.frameCount,
    required this.malformedBytes,
    this.width = 16,
    this.height = 12,
    this.unavailable,
    this.validElsewhere,
  });

  /// The binding under test; it must be available.
  final VideoBinding binding;

  /// A file the binding opens.
  final Uint8List validBytes;

  /// What [validBytes] declares.
  final VideoInfo expectedInfo;

  /// How many frames [validBytes] holds.
  final int frameCount;

  /// Bytes the binding refuses (not a video).
  final Uint8List malformedBytes;

  /// The target width the contract opens at.
  final int width;

  /// The target height the contract opens at.
  final int height;

  /// The file of [validBytes] from a source read in place (a path, a ranged
  /// resource), if the implementation reads one; its cases are skipped
  /// otherwise.
  final VideoSource? validElsewhere;

  /// Builds a binding that is not available, if the implementation can; its
  /// case is skipped otherwise.
  final VideoBinding Function()? unavailable;
}

/// The behaviour every [VideoBinding] shares, run over its fake and over the
/// native binding alike.
abstract final class VideoBindingContract {
  /// Registers the contract's tests; [create] builds a fresh harness for
  /// each.
  static void run(VideoBindingHarness Function() create) {
    group('VideoBinding contract', () {
      late VideoBindingHarness harness;
      late Pointer<Uint8> target;
      late int stride;

      setUp(() {
        harness = create();
        stride = harness.width * 4 + 8;
        target = calloc<Uint8>(stride * harness.height);
      });
      tearDown(() => calloc.free(target));

      VideoHandle open() {
        final result = harness.binding.open(
          VideoSource.bytes(harness.validBytes),
          width: harness.width,
          height: harness.height,
        );
        expect(result, isA<VideoOpened>());
        return (result as VideoOpened).handle;
      }

      VideoFrameResult next(VideoHandle handle) => harness.binding.nextFrame(
        handle,
        target: target,
        strideBytes: stride,
      );

      test('the probe says available, and stays so', () {
        expect(harness.binding.isAvailable, isTrue);
        expect(harness.binding.availability, VideoAvailability.available);
        open();
        expect(harness.binding.availability, VideoAvailability.available);
      });

      test('valid bytes open with the expected info', () {
        final result = harness.binding.open(
          VideoSource.bytes(harness.validBytes),
          width: harness.width,
          height: harness.height,
        );

        expect(result, isA<VideoOpened>());
        expect((result as VideoOpened).info, harness.expectedInfo);
      });

      test('the file read in place opens and decodes as its bytes do', () {
        final elsewhere = harness.validElsewhere;
        if (elsewhere == null) {
          markTestSkipped('the binding reads no other source');
          return;
        }
        final result = harness.binding.open(
          elsewhere,
          width: harness.width,
          height: harness.height,
        );

        expect(result, isA<VideoOpened>());
        final handle = (result as VideoOpened).handle;
        expect(result.info, harness.expectedInfo);
        var frames = 0;
        while (next(handle).status == VideoFrameStatus.frame) {
          frames++;
        }
        expect(frames, harness.frameCount);
        harness.binding.dispose(handle);
      });

      test('bytes that are not a video are rejected, never thrown on', () {
        final result = harness.binding.open(
          VideoSource.bytes(harness.malformedBytes),
          width: harness.width,
          height: harness.height,
        );

        expect(result, isA<VideoRejected>());
        expect(
          (result as VideoRejected).reason,
          isNot(VideoRejection.internal),
        );
      });

      test('a zero target size is a bad size', () {
        final result = harness.binding.open(
          VideoSource.bytes(harness.validBytes),
          width: 0,
          height: harness.height,
        );

        expect(
          result,
          isA<VideoRejected>().having(
            (r) => r.reason,
            'reason',
            VideoRejection.badSize,
          ),
        );
      });

      test('frames come in order, then the end of the stream, which stays', () {
        final handle = open();

        final times = <int>[];
        for (var i = 0; i < harness.frameCount; i++) {
          final result = next(handle);
          expect(result.status, VideoFrameStatus.frame, reason: 'frame $i');
          times.add(result.ptsMs);
        }

        expect(times, orderedEquals([...times]..sort()));
        expect(times.first, 0);
        expect(next(handle).status, VideoFrameStatus.endOfStream);
        expect(next(handle).status, VideoFrameStatus.endOfStream);
      });

      test('rewind restarts the stream from its first frame', () {
        final handle = open();
        final first = next(handle);
        final firstPixels = Uint8List.fromList(
          target.asTypedList(stride * harness.height),
        );
        while (next(handle).status == VideoFrameStatus.frame) {}

        expect(harness.binding.rewind(handle), isTrue);

        final again = next(handle);
        expect(again, first);
        expect(
          target.asTypedList(stride * harness.height),
          orderedEquals(firstPixels),
        );
      });

      group('seek', () {
        // Every frame's time and pixels, from the start.
        (List<int>, List<Uint8List>) readAll(VideoHandle handle) {
          final times = <int>[];
          final pixels = <Uint8List>[];
          for (
            var result = next(handle);
            result.status == VideoFrameStatus.frame;
            result = next(handle)
          ) {
            times.add(result.ptsMs);
            pixels.add(
              Uint8List.fromList(target.asTypedList(stride * harness.height)),
            );
          }
          return (times, pixels);
        }

        Uint8List shown() =>
            Uint8List.fromList(target.asTypedList(stride * harness.height));

        test('forward, to a frame\'s time: that frame comes next', () {
          final handle = open();
          final (times, pixels) = readAll(handle);
          expect(harness.binding.rewind(handle), isTrue);
          final k = times.length ~/ 2;

          expect(
            harness.binding.seek(handle, Duration(milliseconds: times[k])),
            isTrue,
          );

          final result = next(handle);
          expect(result.status, VideoFrameStatus.frame);
          expect(result.ptsMs, times[k]);
          expect(shown(), orderedEquals(pixels[k]));
          expect(next(handle).ptsMs, times[k + 1]);
        });

        test('between two frames: the later one comes next', () {
          final handle = open();
          final (times, _) = readAll(handle);
          final k = times.length ~/ 3;

          harness.binding.seek(handle, Duration(milliseconds: times[k] + 1));

          expect(next(handle).ptsMs, times[k + 1]);
        });

        test('backward, from the end of the stream', () {
          final handle = open();
          final (times, pixels) = readAll(handle);

          expect(
            harness.binding.seek(handle, Duration(milliseconds: times[1])),
            isTrue,
          );

          expect(next(handle).ptsMs, times[1]);
          expect(shown(), orderedEquals(pixels[1]));
        });

        test('near the end, then past it: the last frame, then the end', () {
          final handle = open();
          final (times, pixels) = readAll(handle);

          harness.binding.seek(handle, Duration(milliseconds: times.last));
          expect(next(handle).ptsMs, times.last);
          expect(next(handle).status, VideoFrameStatus.endOfStream);

          harness.binding.seek(
            handle,
            Duration(milliseconds: times.last + 5000),
          );
          final last = next(handle);
          expect(last.status, VideoFrameStatus.frame);
          expect(last.ptsMs, times.last);
          expect(shown(), orderedEquals(pixels.last));
          expect(next(handle).status, VideoFrameStatus.endOfStream);
        });

        test('zero is a rewind; a negative position or an unknown handle is '
            'refused', () {
          final handle = open();
          final (times, _) = readAll(handle);

          expect(harness.binding.seek(handle, Duration.zero), isTrue);
          expect(next(handle).ptsMs, times.first);
          expect(
            harness.binding.seek(handle, const Duration(milliseconds: -1)),
            isFalse,
          );
          expect(
            harness.binding.seek(const VideoHandle(9999), Duration.zero),
            isFalse,
          );
        });
      });

      test('a frame leaves the stride padding of its rows alone', () {
        final handle = open();
        target
            .asTypedList(stride * harness.height)
            .fillRange(0, stride * harness.height, 0x7f);

        next(handle);

        final bytes = target.asTypedList(stride * harness.height);
        for (var y = 0; y < harness.height; y++) {
          expect(
            bytes.sublist(y * stride + harness.width * 4, (y + 1) * stride),
            everyElement(0x7f),
            reason: 'row $y',
          );
        }
      });

      test('a stride under the row width is a bad size', () {
        final handle = open();

        final result = harness.binding.nextFrame(
          handle,
          target: target,
          strideBytes: harness.width * 4 - 1,
        );

        expect(result.status, VideoFrameStatus.badSize);
      });

      test('an unknown handle is a bad argument, and rewind refuses it', () {
        const unknown = VideoHandle(987654);

        expect(next(unknown).status, VideoFrameStatus.badArgument);
        expect(harness.binding.rewind(unknown), isFalse);
      });

      test('a disposed handle is refused; dispose is idempotent', () {
        final handle = open();

        harness.binding
          ..dispose(handle)
          ..dispose(handle);

        expect(next(handle).status, VideoFrameStatus.badArgument);
        expect(harness.binding.rewind(handle), isFalse);
      });

      test('handles are independent', () {
        final a = open();
        final b = open();
        next(a);
        next(a);

        expect(next(b).ptsMs, 0, reason: 'b is still at its first frame');
        harness.binding.dispose(a);
        expect(next(b).status, VideoFrameStatus.frame);
      });

      test(
        'close retires the binding: open throws, dispose stays harmless',
        () {
          final handle = open();

          harness.binding
            ..close()
            ..close()
            ..dispose(handle);

          expect(
            () => harness.binding.open(
              VideoSource.bytes(harness.validBytes),
              width: harness.width,
              height: harness.height,
            ),
            throwsStateError,
          );
        },
      );

      test('an unavailable binding throws StateError from open', () {
        final factory = harness.unavailable;
        if (factory == null) {
          markTestSkipped('this implementation cannot be made unavailable');
          return;
        }
        final binding = factory();

        expect(binding.isAvailable, isFalse);
        expect(
          () => binding.open(
            VideoSource.bytes(harness.validBytes),
            width: harness.width,
            height: harness.height,
          ),
          throwsStateError,
        );
      });
    });
  }
}
