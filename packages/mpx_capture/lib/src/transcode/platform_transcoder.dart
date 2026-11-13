import 'dart:async';

import 'package:mpx_capture/src/job/capture_job.dart';
import 'package:mpx_capture/src/platform/capture_channel.dart';
import 'package:mpx_capture/src/preset/compression_preset.dart';
import 'package:mpx_capture/src/transcode/transcoder.dart';
import 'package:mpx_core/mpx_core.dart';

/// The [Transcoder] over the platform encoders: Media3 Transformer on
/// Android, AVAssetReader into AVAssetWriter on iOS and macOS (an export
/// session only for a passthrough).
///
/// The plan ([CompressionPreset.planFor]) is made here from the native probe,
/// so every platform applies one rule for size, bitrate and passthrough.
/// Platforms run one compression at a time each; jobs started together queue
/// natively.
final class PlatformTranscoder implements Transcoder {
  /// Creates the transcoder; it holds no native resource until [compress].
  const PlatformTranscoder();

  static CaptureChannel get _channel => CaptureChannel.instance;

  @override
  Future<SourceVideo> probe(String path) async {
    final map = await _channel.invoke<Map<Object?, Object?>>('probe', {
      'path': path,
    });
    if (map == null) throw CaptureFailed('not a video: $path');
    return SourceVideo(
      dimensions: MediaDimensions(map['width']! as int, map['height']! as int),
      duration: Duration(microseconds: map['durationUs']! as int),
      codec: switch (map['codec']) {
        'h264' => SourceCodec.h264,
        'hevc' => SourceCodec.hevc,
        _ => SourceCodec.other,
      },
      videoBitrate: map['videoBitrate'] as int?,
      hasAudio: map['hasAudio'] as bool? ?? false,
    );
  }

  @override
  CaptureJob compress(TranscodeRequest request) {
    final id = _channel.nextJobId();
    // Read before the native start: a cancel that lands while the probe runs
    // must keep the native job from starting at all. Once the start is sent,
    // the cancel call follows it on the same channel.
    var cancelled = false;
    final job = CaptureJob(
      onCancel: () async {
        cancelled = true;
        await _channel.invoke<void>('cancel', {'job': id});
      },
    );
    unawaited(_start(id, request, job, () => cancelled));
    return job;
  }

  Future<void> _start(
    int id,
    TranscodeRequest request,
    CaptureJob job,
    bool Function() cancelled,
  ) async {
    try {
      final source = await probe(request.sourcePath);
      if (cancelled()) return;
      final plan = request.preset.planFor(source);
      _channel.register(id, job);
      await _channel.invoke<void>('compress', {
        'job': id,
        'source': request.sourcePath,
        'output': request.outputPath,
        'width': plan.size.width,
        'height': plan.size.height,
        'videoBitrate': plan.videoBitrate,
        'audioBitrate': plan.audioBitrate,
        'audioChannels': plan.audioChannels,
        'passthrough': plan.passthrough,
        'durationUs': source.duration.inMicroseconds,
      });
    } on CaptureException catch (error, stackTrace) {
      job.fail(error, stackTrace);
    }
  }
}
