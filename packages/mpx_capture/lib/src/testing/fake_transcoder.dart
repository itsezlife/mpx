import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:mpx_capture/src/job/capture_job.dart';
import 'package:mpx_capture/src/preset/compression_preset.dart';
import 'package:mpx_capture/src/transcode/transcoder.dart';

/// A [Transcoder] over videos it is told about, writing stand-in files.
///
/// [sources] maps a source path to what [probe] answers for it; any other
/// path is not a video. [compress] plans with [CompressionPreset.planFor] and
/// writes the output in [steps] chunks, one per [stepDelay], reporting after
/// each. The file holds `(video + audio bitrate) × seconds / 8 / 1024` bytes
/// (the real size scaled down, at least [steps]); its first byte is patched at
/// the end, so the completion reports a rewritten head. Output paths are real
/// files: tests pass a temporary directory.
final class FakeTranscoder implements Transcoder {
  /// Creates a fake that knows [sources].
  FakeTranscoder({
    Map<String, SourceVideo>? sources,
    this.steps = 4,
    this.stepDelay = Duration.zero,
  }) : sources = {...?sources};

  /// What [probe] answers, by path. Add to it to introduce a video.
  final Map<String, SourceVideo> sources;

  /// How many chunks an output is written in.
  final int steps;

  /// The wait before each chunk.
  final Duration stepDelay;

  /// Every request [compress] took, in order.
  final List<TranscodeRequest> requests = [];

  /// The plan of every request [compress] took, in order.
  final List<CompressionPlan> plans = [];

  @override
  Future<SourceVideo> probe(String path) async =>
      sources[path] ?? (throw CaptureFailed('not a video: $path'));

  @override
  CaptureJob compress(TranscodeRequest request) {
    requests.add(request);
    var cancelled = false;
    final job = CaptureJob(
      onCancel: () async {
        cancelled = true;
      },
    );
    unawaited(_run(request, job, () => cancelled));
    return job;
  }

  Future<void> _run(
    TranscodeRequest request,
    CaptureJob job,
    bool Function() cancelled,
  ) async {
    final file = File(request.outputPath);
    try {
      await Future<void>.delayed(stepDelay);
      if (cancelled()) return;
      final source = sources[request.sourcePath];
      if (source == null) {
        throw CaptureFailed('not a video: ${request.sourcePath}');
      }
      final plan = request.preset.planFor(source);
      plans.add(plan);
      final seconds = source.duration.inMicroseconds / 1e6;
      final total = math.max(
        steps,
        ((plan.videoBitrate + plan.audioBitrate) * seconds / 8 / 1024).round(),
      );
      final sink = file.openSync(mode: FileMode.write);
      try {
        var written = 0;
        for (var step = 1; step <= steps; step++) {
          await Future<void>.delayed(stepDelay);
          if (cancelled()) return;
          final end = total * step ~/ steps;
          sink.writeFromSync(Uint8List(end - written));
          written = end;
          job.report(
            CaptureProgress(
              bytesWritten: written,
              position: source.duration * (step / steps),
              fraction: step / steps,
            ),
          );
        }
        // The head is patched once the sizes are known, as an MP4 writer does.
        sink
          ..setPositionSync(0)
          ..writeByteSync(1);
      } finally {
        sink.closeSync();
      }
      job.complete(
        CaptureOutput(
          path: request.outputPath,
          size: total,
          duration: source.duration,
          dimensions: plan.size,
          headerRewritten: true,
          reencoded: !plan.passthrough,
        ),
      );
    } on CaptureException catch (error, stackTrace) {
      _deleteQuietly(file);
      job.fail(error, stackTrace);
    } finally {
      if (cancelled()) _deleteQuietly(file);
    }
  }

  static void _deleteQuietly(File file) {
    if (file.existsSync()) file.deleteSync();
  }
}
