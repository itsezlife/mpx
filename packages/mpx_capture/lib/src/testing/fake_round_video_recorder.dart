import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:mpx_capture/src/job/capture_job.dart';
import 'package:mpx_capture/src/round/round_video_recorder.dart';
import 'package:mpx_capture/src/testing/fake_camera.dart';
import 'package:mpx_core/mpx_core.dart';

/// A [RoundVideoRecorder] with no camera: each [tick] records one frame of
/// media time and appends stand-in bytes to the output file.
///
/// A frame adds `videoBitrate / 8 / frameRate / 1024` bytes (the real size
/// scaled down, at least 1); finishing patches the first byte, so the
/// completion reports a rewritten head. [permitted] answers
/// [requestPermission] and gates [start]; [cameras] lists what
/// [RoundVideoRecording.switchCamera] can move between. A recording takes
/// [camera]: a `FakeCameraSessions` over the same one closes when a
/// recording starts, and a session opened later fails the recording as taken
/// over.
final class FakeRoundVideoRecorder implements RoundVideoRecorder {
  /// Creates a fake recorder.
  FakeRoundVideoRecorder({
    this.permitted = true,
    this.cameras = const {CameraFacing.front, CameraFacing.back},
    this.tick = const Duration(milliseconds: 1),
    FakeCamera? camera,
  }) : camera = camera ?? FakeCamera();

  /// The camera recordings own in turn.
  final FakeCamera camera;

  /// Whether camera and microphone are allowed.
  bool permitted;

  /// The cameras the device has.
  final Set<CameraFacing> cameras;

  /// Real time per recorded frame.
  final Duration tick;

  /// Every recording [start] made, in order.
  final List<FakeRoundVideoRecording> recordings = [];

  @override
  Future<bool> requestPermission() async => permitted;

  @override
  Future<RoundVideoRecording> start({
    required String outputPath,
    RoundVideoConfig config = const RoundVideoConfig(),
  }) async {
    if (!permitted) {
      throw const CapturePermissionDenied('camera or microphone not allowed');
    }
    if (cameras.isEmpty) throw const CaptureFailed('no camera');
    final recording = FakeRoundVideoRecording._(
      outputPath: outputPath,
      config: config,
      camera: cameras.contains(config.camera) ? config.camera : cameras.first,
      cameras: cameras,
      tick: tick,
    );
    camera.take(recording, recording._takenOver);
    unawaited(
      recording.job.output
          .then<void>((_) {}, onError: (Object _) {})
          .whenComplete(() => camera.drop(recording)),
    );
    recordings.add(recording);
    return recording;
  }
}

/// A recording of [FakeRoundVideoRecorder].
final class FakeRoundVideoRecording implements RoundVideoRecording {
  FakeRoundVideoRecording._({
    required String outputPath,
    required this.config,
    required CameraFacing camera,
    required Set<CameraFacing> cameras,
    required Duration tick,
  }) : _camera = camera,
       _cameras = cameras,
       _file = File(outputPath).openSync(mode: FileMode.write),
       _path = outputPath {
    job = CaptureJob(onCancel: () async => _discard());
    _frameBytes = math.max(
      1,
      config.videoBitrate ~/ 8 ~/ config.frameRate ~/ 1024,
    );
    _timer = Timer.periodic(tick, (_) => _frame());
  }

  @override
  late final CaptureJob job;

  @override
  final RoundVideoConfig config;

  final Set<CameraFacing> _cameras;
  final String _path;
  final RandomAccessFile _file;
  late final int _frameBytes;
  late final Timer _timer;
  CameraFacing _camera;
  var _paused = false;
  var _frames = 0;
  var _written = 0;
  var _closed = false;

  /// How many times the camera moved.
  int switches = 0;

  @override
  int? get textureId => null;

  @override
  MediaDimensions get previewSize => const MediaDimensions(480, 640);

  @override
  CameraFacing get camera => _camera;

  @override
  bool get isPaused => _paused;

  Duration get _position =>
      Duration(microseconds: _frames * 1000000 ~/ config.frameRate);

  @override
  Future<void> pause() async {
    if (!job.isDone) _paused = true;
  }

  @override
  Future<void> resume() async {
    if (!job.isDone) _paused = false;
  }

  @override
  Future<CameraFacing> switchCamera() async {
    if (job.isDone) return _camera;
    final other = _cameras.where((c) => c != _camera);
    if (other.isNotEmpty) {
      _camera = other.first;
      switches++;
    }
    return _camera;
  }

  @override
  Future<CaptureOutput> stop() {
    _finish();
    return job.output;
  }

  void _frame() {
    if (_paused || job.isDone) return;
    _file.writeFromSync(Uint8List(_frameBytes));
    _written += _frameBytes;
    _frames++;
    job.report(
      CaptureProgress(
        bytesWritten: _written,
        position: _position,
        fraction: math.min(
          1,
          _position.inMicroseconds / config.maxDuration.inMicroseconds,
        ),
      ),
    );
    if (_position >= config.maxDuration) _finish();
  }

  void _finish() {
    if (job.isDone || _closed) return;
    // The head is patched once the sizes are known, as an MP4 writer does.
    if (_written > 0) {
      _file
        ..setPositionSync(0)
        ..writeByteSync(1);
    }
    _close();
    job.complete(
      CaptureOutput(
        path: _path,
        size: _written,
        duration: _position,
        dimensions: MediaDimensions(config.side, config.side),
        headerRewritten: true,
      ),
      fraction: math.min(
        1,
        _position.inMicroseconds / config.maxDuration.inMicroseconds,
      ),
    );
  }

  void _takenOver() {
    if (job.isDone) return;
    _discard();
    job.fail(const CaptureFailed('camera taken over'));
  }

  void _discard() {
    _close();
    final file = File(_path);
    if (file.existsSync()) file.deleteSync();
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    _timer.cancel();
    _file.closeSync();
  }
}
