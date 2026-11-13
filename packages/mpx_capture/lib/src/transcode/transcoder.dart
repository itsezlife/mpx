import 'package:flutter/foundation.dart';
import 'package:mpx_capture/src/job/capture_job.dart';
import 'package:mpx_capture/src/preset/compression_preset.dart';

/// One video to compress before send.
@immutable
final class TranscodeRequest {
  /// Asks to compress the video at [sourcePath] into [outputPath] at
  /// [preset].
  const TranscodeRequest({
    required this.sourcePath,
    required this.outputPath,
    required this.preset,
  });

  /// Absolute path of the video to compress.
  final String sourcePath;

  /// Absolute path of the MP4 to write; an existing file is replaced. The
  /// directory must exist.
  final String outputPath;

  /// The step of the shared table to compress at.
  final CompressionPreset preset;

  @override
  String toString() => 'TranscodeRequest($sourcePath -> $outputPath, $preset)';
}

/// Compresses a picked video against the shared [CompressionPreset] table
/// before it is sent.
///
/// The output is an MP4 with H.264 video at the plan's size and bitrate
/// ([CompressionPreset.planFor]) and AAC audio, a keyframe every second; a
/// source that would not change is remuxed instead. The job reports bytes
/// written and the encode position while it runs, and the final size and
/// whether the file's head was rewritten when it finishes.
///
/// Implementations: `PlatformTranscoder` (the platform encoders) and the fake
/// in `testing.dart`; both meet `TranscoderContract`.
abstract interface class Transcoder {
  /// Reads what compression needs to know about the video at [path].
  ///
  /// Throws [CaptureFailed] when it is not a readable video.
  Future<SourceVideo> probe(String path);

  /// Starts compressing [request.sourcePath]. The job fails with
  /// [CaptureFailed] when the source is not a readable video or encoding
  /// fails; its output file is deleted then, and on cancel.
  CaptureJob compress(TranscodeRequest request);
}
