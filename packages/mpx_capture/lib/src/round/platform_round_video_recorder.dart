import 'dart:async';

import 'package:mpx_capture/src/camera/camera_claim.dart';
import 'package:mpx_capture/src/job/capture_job.dart';
import 'package:mpx_capture/src/platform/capture_channel.dart';
import 'package:mpx_capture/src/round/round_video_recorder.dart';
import 'package:mpx_core/mpx_core.dart';

/// The [RoundVideoRecorder] over the platform cameras: CameraX through a GL
/// stage into MediaCodec on Android, AVCaptureSession into AVAssetWriter on
/// iOS and macOS. The preview is a Flutter texture ([RoundVideoPreview]
/// shows it).
///
/// The front camera is mirrored in the preview and in the file. One
/// recording runs at a time.
final class PlatformRoundVideoRecorder implements RoundVideoRecorder {
  /// Creates the recorder; it holds no native resource until [start].
  const PlatformRoundVideoRecorder();

  static CaptureChannel get _channel => CaptureChannel.instance;

  @override
  Future<bool> requestPermission() async =>
      await _channel.invoke<bool>('permissions') ?? false;

  @override
  Future<RoundVideoRecording> start({
    required String outputPath,
    RoundVideoConfig config = const RoundVideoConfig(),
  }) async {
    final id = _channel.nextJobId();
    final job = CaptureJob(
      onCancel: () => _channel.invoke<void>('cancel', {'job': id}),
    );
    _channel.register(id, job);
    // The camera has one owner: a session open now closes, and a session
    // opened later fails this recording as taken over.
    final owner = Object();
    CameraClaim.take(
      owner,
      () => job.fail(const CaptureFailed('camera taken over')),
    );
    job.output.ignore();
    unawaited(
      job.output
          .then<void>((_) {}, onError: (Object _) {})
          .whenComplete(() => CameraClaim.drop(owner)),
    );
    try {
      final started = await _channel
          .invoke<Map<Object?, Object?>>('roundStart', {
            'job': id,
            'output': outputPath,
            'side': config.side,
            'videoBitrate': config.videoBitrate,
            'frameRate': config.frameRate,
            'audioBitrate': config.audioBitrate,
            'maxDurationUs': config.maxDuration.inMicroseconds,
            'camera': config.camera.name,
          });
      if (started == null) throw const CaptureFailed('camera did not start');
      return _PlatformRoundVideoRecording(
        id: id,
        job: job,
        config: config,
        textureId: started['textureId']! as int,
        previewSize: MediaDimensions(
          started['previewWidth']! as int,
          started['previewHeight']! as int,
        ),
        camera: CameraFacing.values.byName(started['camera']! as String),
      );
    } on CaptureException catch (error, stackTrace) {
      job.fail(error, stackTrace);
      rethrow;
    }
  }
}

final class _PlatformRoundVideoRecording implements RoundVideoRecording {
  _PlatformRoundVideoRecording({
    required int id,
    required this.job,
    required this.config,
    required this.textureId,
    required this.previewSize,
    required CameraFacing camera,
  }) : _id = id,
       _camera = camera;

  final int _id;

  @override
  final CaptureJob job;

  @override
  final RoundVideoConfig config;

  @override
  final int textureId;

  @override
  final MediaDimensions previewSize;

  CameraFacing _camera;
  var _paused = false;

  @override
  CameraFacing get camera => _camera;

  @override
  bool get isPaused => _paused;

  Map<String, Object?> get _args => {'job': _id};

  @override
  Future<void> pause() async {
    if (job.isDone || _paused) return;
    _paused = true;
    await CaptureChannel.instance.invoke<void>('roundPause', _args);
  }

  @override
  Future<void> resume() async {
    if (job.isDone || !_paused) return;
    _paused = false;
    await CaptureChannel.instance.invoke<void>('roundResume', _args);
  }

  @override
  Future<CameraFacing> switchCamera() async {
    if (job.isDone) return _camera;
    final facing = await CaptureChannel.instance.invoke<String>(
      'roundSwitchCamera',
      _args,
    );
    if (facing != null) _camera = CameraFacing.values.byName(facing);
    return _camera;
  }

  @override
  Future<CaptureOutput> stop() async {
    if (!job.isDone) {
      await CaptureChannel.instance.invoke<void>('roundStop', _args);
    }
    return job.output;
  }
}
