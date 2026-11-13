import 'package:flutter/foundation.dart';
import 'package:mpx_capture/src/job/capture_job.dart';
import 'package:mpx_core/mpx_core.dart';

/// Which camera a round video records from.
enum CameraFacing {
  /// The camera on the screen's side.
  front,

  /// The camera on the far side.
  back,
}

/// The encoding and limits of a round video message.
///
/// The defaults are the shared values: a 384 px square, about 1 Mbps H.264 at
/// 30 fps with a keyframe every second, 64 kbps AAC, at most 60 seconds. A
/// host that gets other values from its server passes them here.
@immutable
final class RoundVideoConfig {
  /// Creates a config; [side] must be even and at least 2.
  const RoundVideoConfig({
    this.side = 384,
    this.videoBitrate = 1000000,
    this.frameRate = 30,
    this.audioBitrate = 64000,
    this.maxDuration = const Duration(seconds: 60),
    this.camera = CameraFacing.front,
  }) : assert(side >= 2 && side % 2 == 0, 'side must be even and >= 2');

  /// Width and height of the square output, in pixels.
  final int side;

  /// The video bitrate in bits per second.
  final int videoBitrate;

  /// Frames per second.
  final int frameRate;

  /// The mono AAC bitrate in bits per second.
  final int audioBitrate;

  /// The longest recording; reaching it finishes the recording.
  final Duration maxDuration;

  /// The camera to start with.
  final CameraFacing camera;

  @override
  bool operator ==(Object other) =>
      other is RoundVideoConfig &&
      other.side == side &&
      other.videoBitrate == videoBitrate &&
      other.frameRate == frameRate &&
      other.audioBitrate == audioBitrate &&
      other.maxDuration == maxDuration &&
      other.camera == camera;

  @override
  int get hashCode => Object.hash(
    side,
    videoBitrate,
    frameRate,
    audioBitrate,
    maxDuration,
    camera,
  );

  @override
  String toString() =>
      'RoundVideoConfig(${side}px, $videoBitrate bps @ $frameRate fps, '
      'audio $audioBitrate bps, max $maxDuration, $camera)';
}

/// Records round video messages: a square crop of the camera with
/// microphone audio, written as an MP4 while a preview shows.
///
/// Camera and microphone permissions are this package's; [requestPermission]
/// asks for both. Implementations: `PlatformRoundVideoRecorder` (CameraX
/// through a GL stage into MediaCodec on Android, AVCaptureSession into
/// AVAssetWriter on iOS and macOS) and the fake in `testing.dart`; both meet
/// `RoundVideoRecorderContract`.
abstract interface class RoundVideoRecorder {
  /// Asks for camera and microphone access; true when both are granted.
  Future<bool> requestPermission();

  /// Opens the camera and starts recording into [outputPath] (an MP4; an
  /// existing file is replaced).
  ///
  /// Completes once frames flow. Throws [CapturePermissionDenied] without
  /// access, [CaptureFailed] when no camera can be opened.
  Future<RoundVideoRecording> start({
    required String outputPath,
    RoundVideoConfig config = const RoundVideoConfig(),
  });
}

/// One round video being recorded.
///
/// [job] reports progress (recorded time over the longest allowed) and
/// settles with the file when [stop] is called or the longest allowed time is
/// reached; [CaptureJob.cancel] discards it. Every control is a no-op once the
/// job settled.
abstract interface class RoundVideoRecording {
  /// Progress, output and cancel.
  CaptureJob get job;

  /// The config the recording runs with.
  RoundVideoConfig get config;

  /// The texture that shows the camera, or null when there is none (a fake).
  int? get textureId;

  /// The size of the preview frames; the preview is cropped to a square
  /// from their centre, as the output is.
  MediaDimensions get previewSize;

  /// The camera recording now.
  CameraFacing get camera;

  /// Whether recording is paused (the preview keeps running).
  bool get isPaused;

  /// Stops adding frames until [resume]; paused time is not recorded.
  Future<void> pause();

  /// Continues after [pause].
  Future<void> resume();

  /// Moves to the other camera without breaking the recording; returns the
  /// camera now in use (the same one when the device has no other).
  Future<CameraFacing> switchCamera();

  /// Finishes the file; the same future as [job]'s output.
  Future<CaptureOutput> stop();
}
