import 'dart:async';
import 'dart:io';
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';
import 'package:mpx_capture/src/camera/camera_background.dart';
import 'package:mpx_capture/src/camera/camera_session.dart';
import 'package:mpx_capture/src/camera/camera_snapshots.dart';
import 'package:mpx_capture/src/job/capture_job.dart';
import 'package:mpx_capture/src/round/round_video_recorder.dart';
import 'package:mpx_capture/src/testing/fake_camera.dart';
import 'package:mpx_core/mpx_core.dart';

/// [CameraSessions] without a camera, for tests and for hosts without a
/// device: sessions open at once, captures write stand-in files. Meets
/// `CameraSessionContract`.
final class FakeCameraSessions implements CameraSessions {
  /// Creates the opener. Without [allowed] sessions open denied; [cameras]
  /// says how many cameras there are (one cannot switch); [hasFlash] and
  /// [textureId] are what every session reports. Sessions take [camera]
  /// (a fresh one by default); a `FakeRoundVideoRecorder` over the same one
  /// takes it over, and is taken over by a session.
  FakeCameraSessions({
    this.allowed = true,
    this.cameras = 2,
    this.hasFlash = true,
    this.textureId,
    this.holdsSwitchFrames = false,
    FakeCamera? camera,
  }) : camera = camera ?? FakeCamera();

  /// The camera the sessions own in turn.
  final FakeCamera camera;

  /// Whether camera access is granted.
  bool allowed;

  /// How many cameras there are.
  final int cameras;

  /// Whether the cameras have a flash.
  final bool hasFlash;

  /// The texture every session reports, or null.
  final int? textureId;

  /// Whether a switch waits for [FakeCameraSession.deliverSwitchFrames]
  /// before the new camera's first frame (`isSwitching` true until then);
  /// otherwise the first frame comes with the switch.
  final bool holdsSwitchFrames;

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
    camera.take(session, session._close);
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
    : _value = ValueNotifier(initial) {
    _background = CameraBackground(
      onHide: () => unawaited(_release()),
      onShow: _reopen,
    );
  }

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
    await CameraSnapshots.takeAll(this, switching: true);
    final next = _now.facing == CameraFacing.front
        ? CameraFacing.back
        : CameraFacing.front;
    _value.value = _now.copyWith(
      facing: next,
      isSwitching: _owner.holdsSwitchFrames,
    );
    return next;
  }

  /// The camera's first frame after a switch or a resume, for an opener
  /// that [FakeCameraSessions.holdsSwitchFrames].
  void deliverSwitchFrames() {
    if (_disposed || !(_now.isSwitching || _now.awaitingFrames)) return;
    _value.value = _now.copyWith(isSwitching: false, awaitingFrames: false);
  }

  /// The points focused at, in order.
  final List<Offset> focusedAt = [];

  @override
  Future<void> setZoom(double zoom) async {
    _open();
    _value.value = _now.copyWith(zoom: zoom.clamp(0.0, 1.0));
  }

  @override
  Future<void> focusAt(Offset point) async {
    _open();
    CameraFocus.check(point);
    focusedAt.add(point);
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
    if (!_hidden) await CameraSnapshots.takeAll(this, switching: false);
    _value.value = _now.copyWith(isPaused: true, awaitingFrames: true);
  }

  @override
  Future<void> resume() async {
    _open();
    _value.value = _now.copyWith(
      isPaused: false,
      awaitingFrames: _hidden || _owner.holdsSwitchFrames,
    );
  }

  // --- The app in the background ---

  late final CameraBackground _background;
  bool _hidden = false;

  /// Whether the camera is let go now: paused by the host, or the app is
  /// hidden.
  bool get isReleased =>
      _now.state != CameraSessionState.closed && (_now.isPaused || _hidden);

  Future<void> _release() async {
    if (_hidden || _now.state == CameraSessionState.closed) return;
    _hidden = true;
    if (_now.isPaused) return;
    if (_now.isRecording) await stopRecording();
    await CameraSnapshots.takeAll(this, switching: false);
    if (_now.state == CameraSessionState.closed) return;
    _value.value = _now.copyWith(awaitingFrames: true);
  }

  void _reopen() {
    if (!_hidden) return;
    _hidden = false;
    if (_now.state == CameraSessionState.closed || _now.isPaused) return;
    _value.value = _now.copyWith(awaitingFrames: _owner.holdsSwitchFrames);
  }

  /// Whether each photo taken was saved mirrored, in order.
  final List<bool> photosMirrored = [];

  @override
  Future<CaptureOutput> capturePhoto({
    required String outputPath,
    bool mirrorFront = false,
  }) async {
    _available();
    photosMirrored.add(mirrorFront && _now.facing == CameraFacing.front);
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
    _owner.camera.drop(this);
    if (identical(_owner.current, this)) _owner.current = null;
  }

  void _close() {
    _background.dispose();
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
