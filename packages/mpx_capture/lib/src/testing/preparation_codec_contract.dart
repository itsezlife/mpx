import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_capture/src/job/capture_job.dart';
import 'package:mpx_capture/src/prepare/preparation_codec.dart';
import 'package:mpx_capture/src/prepare/preparation_policy.dart';

/// What a [PreparationCodec] contract run needs: the codec, a JPEG whose
/// long side is above 1280, a video, a file that is no media and a
/// directory for outputs.
final class PreparationCodecHarness {
  /// Creates a harness.
  const PreparationCodecHarness({
    required this.codec,
    required this.jpeg,
    required this.video,
    required this.notMedia,
    required this.outputDirectory,
  });

  /// The codec under test.
  final PreparationCodec codec;

  /// Path of a JPEG whose long side is above 1280.
  final String jpeg;

  /// Path of a readable video.
  final String video;

  /// Path of a file that is neither a still nor a video.
  final String notMedia;

  /// An existing, writable directory.
  final String outputDirectory;
}

/// The contract every [PreparationCodec] meets; see its documentation.
abstract final class PreparationCodecContract {
  /// Runs it as a test group. [create] builds a fresh harness for each test.
  static void run(PreparationCodecHarness Function() create) {
    group('PreparationCodec contract', () {
      late PreparationCodecHarness harness;
      var outputs = 0;

      setUp(() => harness = create());

      String nextOutput() =>
          '${harness.outputDirectory}/codec-contract-${outputs++}.jpg';

      test('probes a JPEG', () async {
        final still = await harness.codec.probeStill(harness.jpeg);
        expect(
          math.max(still.dimensions.width, still.dimensions.height),
          greaterThan(1280),
        );
        expect(still.isJpeg, isTrue);
        expect(still.byteSize, greaterThan(0));
        expect(still.animated, isFalse);
      });

      test('a file that is no still fails the probe', () async {
        await expectLater(
          harness.codec.probeStill(harness.notMedia),
          throwsA(isA<CaptureFailed>()),
        );
      });

      test('encodes into a file within the side, keeping the aspect', () async {
        final source = await harness.codec.probeStill(harness.jpeg);
        final path = nextOutput();
        final encoded = await harness.codec.encodeStill(
          harness.jpeg,
          maxSide: 1280,
          quality: 80,
          outputPath: path,
        );
        final size = encoded.dimensions;
        expect(math.max(size.width, size.height), 1280);
        final sourceAspect = source.dimensions.width / source.dimensions.height;
        expect(size.width / size.height, closeTo(sourceAspect, 0.01));
        expect(File(path).lengthSync(), encoded.byteSize);
        expect(encoded.bytes, isNull);
      });

      test('a side above the source never scales up', () async {
        final source = await harness.codec.probeStill(harness.jpeg);
        final encoded = await harness.codec.encodeStill(
          harness.jpeg,
          maxSide: 100000,
          quality: 60,
          outputPath: nextOutput(),
        );
        expect(encoded.dimensions, source.dimensions);
      });

      test('encodes into memory', () async {
        final encoded = await harness.codec.encodeStill(
          harness.jpeg,
          maxSide: 320,
          quality: 40,
        );
        expect(encoded.bytes, isNotEmpty);
        expect(encoded.bytes!.length, encoded.byteSize);
        expect(
          math.max(encoded.dimensions.width, encoded.dimensions.height),
          320,
        );
      });

      test('draws a video poster within the side', () async {
        final poster = await harness.codec.videoThumbnail(
          harness.video,
          const ThumbnailSpec(side: 90, quality: 55),
        );
        expect(poster.bytes, isNotEmpty);
        expect(
          math.max(poster.dimensions.width, poster.dimensions.height),
          lessThanOrEqualTo(90),
        );
      });

      test('a file that is no video has no poster', () async {
        await expectLater(
          harness.codec.videoThumbnail(
            harness.notMedia,
            const ThumbnailSpec(side: 90, quality: 55),
          ),
          throwsA(isA<CaptureFailed>()),
        );
      });
    });
  }
}
