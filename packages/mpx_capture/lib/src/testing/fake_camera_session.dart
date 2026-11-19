import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mpx_capture/src/camera/camera_session.dart';
import 'package:mpx_capture/src/job/capture_job.dart';
import 'package:mpx_capture/src/round/round_video_recorder.dart';
import 'package:mpx_core/mpx_core.dart';

/// [CameraSessions] without a camera, for tests and for hosts without a
/// device: sessions open at once, captures write stand-in files. Meets
/// `CameraSessionContract`.
final class FakeCameraSessions implements CameraSessions {
  /// Creates the opener. Without [allowed] sessions open denied; [cameras]
  /// says how many cameras there are (one cannot switch); [hasFlash] and
  /// [textureId] are what every session reports.
  FakeCameraSessions({
    this.allowed = true,
    this.cameras = 2,
    this.hasFlash = true,
    this.textureId,
  });

  /// Whether camera access is granted.
  bool allowed;

  /// How many cameras there are.
  final int cameras;

  /// Whether the cameras have a flash.
  final bool hasFlash;

  /// The texture every session reports, or null.
  final int? textureId;

  /// How many sessions were opened.
  int openCount = 0;

  /// The open session, if any.
  FakeCameraSession? current;

  @override
  Future<CameraSession> open({
    CameraFacing facing = CameraFacing.back,
    int? frameRateCap,
    bool audio = true,
  }) async {
    await current?._takeOver();
    openCount++;
    final session = FakeCameraSession._(
      this,
      CameraSessionValue(
        state: allowed
            ? CameraSessionState.available
            : CameraSessionState.denied,
        facing: cameras < 2 ? CameraFacing.back : facing,
        textureId: allowed ? textureId : null,
        previewSize: allowed ? const MediaDimensions(1080, 1920) : null,
        hasFlash: hasFlash,
        canSwitchCamera: cameras > 1,
        frameRateCap: frameRateCap,
      ),
    );
    current = session;
    return session;
  }
}

/// A [CameraSession] of [FakeCameraSessions].
///
/// A photo is a stand-in JPEG of 3024 x 4032; a video is a stand-in MP4 of
/// 1080 x 1920 whose duration is the time it recorded.
final class FakeCameraSession implements CameraSession {
  FakeCameraSession._(this._owner, CameraSessionValue initial)
    : _value = ValueNotifier(initial);

  final FakeCameraSessions _owner;
  final ValueNotifier<CameraSessionValue> _value;
  final Stopwatch _recording = Stopwatch();
  String? _recordingPath;
  bool _disposed = false;

  /// Every cap set, in order.
  final List<int?> frameRateCaps = [];

  /// Photos taken.
  int photos = 0;

  @override
  ValueListenable<CameraSessionValue> get value => _value;

  CameraSessionValue get _now => _value.value;

  @override
  Future<void> setFrameRateCap(int? fps) async {
    _open();
    frameRateCaps.add(fps);
    _value.value = _now.copyWith(frameRateCap: fps, replaceFrameRateCap: true);
  }

  @override
  Future<CameraFacing> switchCamera() async {
    _open();
    if (!_now.canSwitchCamera) return _now.facing;
    final next = _now.facing == CameraFacing.front
        ? CameraFacing.back
        : CameraFacing.front;
    _value.value = _now.copyWith(facing: next);
    return next;
  }

  @override
  Future<void> setFlash(CameraFlash flash) async {
    _open();
    _value.value = _now.copyWith(flash: flash);
  }

  @override
  Future<void> pause() async {
    _open();
    if (_now.isRecording) await stopRecording();
    _value.value = _now.copyWith(isPaused: true);
  }

  @override
  Future<void> resume() async {
    _open();
    _value.value = _now.copyWith(isPaused: false);
  }

  @override
  Future<CaptureOutput> capturePhoto({required String outputPath}) async {
    _available();
    final bytes = Uint8List.fromList(List.filled(2048, 0xff));
    File(outputPath).writeAsBytesSync(bytes);
    photos++;
    return CaptureOutput(
      path: outputPath,
      size: bytes.length,
      duration: Duration.zero,
      dimensions: const MediaDimensions(3024, 4032),
      headerRewritten: false,
    );
  }

  @override
  Future<void> startRecording({required String outputPath}) async {
    _available();
    if (_now.isRecording) throw const CaptureFailed('already recording');
    _recordingPath = outputPath;
    _recording
      ..reset()
      ..start();
    _value.value = _now.copyWith(isRecording: true);
  }

  @override
  Future<CaptureOutput> stopRecording() async {
    _open();
    final path = _recordingPath;
    if (!_now.isRecording || path == null) {
      throw const CaptureFailed('not recording');
    }
    _recording.stop();
    _recordingPath = null;
    final bytes = Uint8List(4096);
    File(path).writeAsBytesSync(bytes);
    _value.value = _now.copyWith(isRecording: false);
    return CaptureOutput(
      path: path,
      size: bytes.length,
      duration: _recording.elapsed,
      dimensions: const MediaDimensions(1080, 1920),
      headerRewritten: true,
    );
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _close();
    if (identical(_owner.current, this)) _owner.current = null;
  }

  Future<void> _takeOver() async => _close();

  void _close() {
    if (_now.state == CameraSessionState.closed) return;
    _recording.stop();
    _value.value = const CameraSessionValue(state: CameraSessionState.closed);
  }

  void _open() {
    if (_now.state == CameraSessionState.closed) {
      throw const CaptureFailed('camera session closed');
    }
  }

  void _available() {
    _open();
    if (!_now.isAvailable || _now.isPaused) {
      throw CaptureFailed('camera not available (${_now.state.name})');
    }
  }
}
