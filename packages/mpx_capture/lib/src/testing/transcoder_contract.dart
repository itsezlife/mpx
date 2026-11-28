import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_capture/src/job/capture_job.dart';
import 'package:mpx_capture/src/preset/compression_preset.dart';
import 'package:mpx_capture/src/transcode/transcoder.dart';
import 'package:mpx_core/mpx_core.dart';

/// What a [Transcoder] contract run needs: the transcoder, a video it can
/// read, a file that is not a video and a directory for outputs.
final class TranscoderHarness {
  /// Creates a harness.
  ///
  /// [source] must be a video at least a second long whose long side is
  /// above [CompressionPreset.veryLow]'s, so compressing it scales it down.
  const TranscoderHarness({
    required this.transcoder,
    required this.source,
    required this.notAVideo,
    required this.outputDirectory,
    this.reprobeOutputs = false,
  });

  /// The transcoder under test.
  final Transcoder transcoder;

  /// Path of a readable video.
  final String source;

  /// Path of a file that is not a video.
  final String notAVideo;

  /// An existing, writable directory.
  final String outputDirectory;

  /// Whether outputs are real videos the transcoder can probe again (true for
  /// platform transcoders; a fake writes stand-in bytes).
  final bool reprobeOutputs;
}

/// The contract every [Transcoder] meets; see its documentation.
abstract final class TranscoderContract {
  /// Runs it as a test group. [create] builds a fresh harness for each test.
  static void run(TranscoderHarness Function() create) {
    group('Transcoder contract', () {
      late TranscoderHarness harness;
      var outputs = 0;

      setUp(() => harness = create());

      String nextOutput() =>
          '${harness.outputDirectory}/contract-${outputs++}.mp4';

      test('probe reads the source video', () async {
        final source = await harness.transcoder.probe(harness.source);
        expect(
          math.max(source.dimensions.width, source.dimensions.height),
          greaterThan(CompressionPreset.veryLow.maxSide),
        );
        expect(
          source.duration,
          greaterThanOrEqualTo(const Duration(seconds: 1)),
        );
      });

      test('probe of a file that is not a video fails', () async {
        await expectLater(
          harness.transcoder.probe(harness.notAVideo),
          throwsA(isA<CaptureFailed>()),
        );
      });

      test('compress writes the planned output and reports it', () async {
        const preset = CompressionPreset.veryLow;
        final path = nextOutput();
        final job = harness.transcoder.compress(
          TranscodeRequest(
            sourcePath: harness.source,
            outputPath: path,
            preset: preset,
          ),
        );
        final reports = <CaptureProgress>[];
        job.progress.listen(reports.add);
        final output = await job.output;

        expect(output.path, path);
        expect(File(path).lengthSync(), output.size);
        expect(output.size, greaterThan(0));
        expect(output.reencoded, isTrue);
        expect(
          math.max(output.dimensions.width, output.dimensions.height),
          lessThanOrEqualTo(preset.maxSide),
        );
        expect(output.duration, greaterThan(Duration.zero));

        expect(reports, isNotEmpty);
        final last = reports.last;
        expect(last.isFinal, isTrue);
        expect(last.finalSize, output.size);
        expect(last.headerRewritten, output.headerRewritten);
        expect(job.latest, last);
        expect(reports.where((r) => r.isFinal), hasLength(1));
        for (var i = 1; i < reports.length; i++) {
          expect(
            reports[i].bytesWritten,
            greaterThanOrEqualTo(reports[i - 1].bytesWritten),
            reason: 'bytes written never shrink',
          );
          expect(
            reports[i].fraction,
            greaterThanOrEqualTo(reports[i - 1].fraction),
            reason: 'progress never goes back',
          );
        }
        for (final report in reports) {
          expect(report.fraction, inInclusiveRange(0, 1));
        }

        if (harness.reprobeOutputs) {
          final written = await harness.transcoder.probe(path);
          expect(written.codec, SourceCodec.h264);
          expect(written.dimensions, output.dimensions);
          expect(
            written.videoBitrate,
            anyOf(isNull, lessThan(preset.videoBitrate * 1.5)),
            reason: 'the output holds the preset bitrate',
          );
        }
      });

      test('cancel stops the job and deletes the output', () async {
        final path = nextOutput();
        final job = harness.transcoder.compress(
          TranscodeRequest(
            sourcePath: harness.source,
            outputPath: path,
            preset: CompressionPreset.veryLow,
          ),
        );
        await job.cancel();
        await expectLater(job.output, throwsA(isA<CaptureCancelled>()));
        expect(job.isDone, isTrue);
        expect(File(path).existsSync(), isFalse);
      });

      test('cancel after completion changes nothing', () async {
        final path = nextOutput();
        final job = harness.transcoder.compress(
          TranscodeRequest(
            sourcePath: harness.source,
            outputPath: path,
            preset: CompressionPreset.veryLow,
          ),
        );
        final output = await job.output;
        await job.cancel();
        expect(await job.output, output);
        expect(File(path).existsSync(), isTrue);
      });

      test('a source that is not a video fails the job', () async {
        final path = nextOutput();
        final job = harness.transcoder.compress(
          TranscodeRequest(
            sourcePath: harness.notAVideo,
            outputPath: path,
            preset: CompressionPreset.veryLow,
          ),
        );
        await expectLater(job.output, throwsA(isA<CaptureFailed>()));
        expect(File(path).existsSync(), isFalse);
      });
    });
  }
}
