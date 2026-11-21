import 'dart:async';
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';
import 'package:mpx_capture/src/camera/camera_background.dart';
import 'package:mpx_capture/src/camera/camera_claim.dart';
import 'package:mpx_capture/src/camera/camera_session.dart';
import 'package:mpx_capture/src/camera/camera_snapshots.dart';
import 'package:mpx_capture/src/job/capture_job.dart';
import 'package:mpx_capture/src/platform/capture_channel.dart';
import 'package:mpx_capture/src/round/round_video_recorder.dart';
import 'package:mpx_core/mpx_core.dart';

/// The [CameraSessions] over the platform cameras: CameraX (preview,
/// image capture and video capture) on Android, AVCaptureSession (a video
/// data output into a Flutter texture, a photo output, an asset writer) on
/// iOS and macOS. iOS records without sound while a call is active.
///
/// One camera owner per process: opening a session closes the session
/// before and fails a running round video recording as taken over, and a
/// round video recording closes the session.
final class PlatformCameraSessions implements CameraSessions {
  /// Creates the opener; it holds nothing until [open].
  const PlatformCameraSessions();

  static CaptureChannel get _channel => CaptureChannel.instance;

  @override
  Future<CameraSession> open({
    CameraFacing facing = CameraFacing.back,
    int? frameRateCap,
    bool audio = true,
  }) async {
    final id = _channel.nextJobId();
    final session = _PlatformCameraSession(
      id,
      CameraSessionValue(facing: facing, frameRateCap: frameRateCap),
    );
    CameraClaim.take(session, session._closedHere);
    _channel.listen(id, session._onEvent);
    try {
      final opened = await _channel.invoke<Map<Object?, Object?>>(
        'cameraOpen',
        {
          'id': id,
          'facing': facing.name,
          'frameRateCap': frameRateCap,
          'audio': audio,
        },
      );
      session._apply(opened ?? const {'state': 'failed'});
    } on CapturePermissionDenied {
      session._apply(const {'state': 'denied'});
    } on CaptureException {
      session._apply(const {'state': 'failed'});
    }
    return session;
  }
}

final class _PlatformCameraSession implements CameraSession {
  _PlatformCameraSession(this._id, CameraSessionValue initial)
    : _value = ValueNotifier(initial) {
    _background = CameraBackground(
      onHide: () => unawaited(_release()),
      onShow: () => unawaited(_reopen()),
    );
  }

  // --- The app in the background ---

  // While the app is hidden the camera is let go (another app may want
  // it), whatever the host asked; the previews hold their last frame, and
  // the camera opens again when the app shows, unless the host paused it.
  late final CameraBackground _background;
  bool _hidden = false;

  Future<void> _release() async {
    if (_hidden || _now.state == CameraSessionState.closed) return;
    _hidden = true;
    if (_now.isPaused) return;
    _switchTimer?.cancel();
    if (_now.isRecording) await _quietly(stopRecording);
    await CameraSnapshots.takeAll(this, switching: false);
    if (!_hidden || _now.state == CameraSessionState.closed) return;
    await _quietly(() => _channel.invoke<void>('cameraPause', _args()));
    if (_now.state == CameraSessionState.closed) return;
    _value.value = _now.copyWith(awaitingFrames: true);
  }

  Future<void> _reopen() async {
    if (!_hidden) return;
    _hidden = false;
    if (_now.state == CameraSessionState.closed || _now.isPaused) return;
    await _quietly(() => _channel.invoke<void>('cameraResume', _args()));
    _switchTimer?.cancel();
    _switchTimer = Timer(_switchWait, _switched);
  }

  static Future<void> _quietly(Future<Object?> Function() call) async {
    try {
      await call();
    } on Object {
      // The session closed meanwhile.
    }
  }

  final int _id;
  final ValueNotifier<CameraSessionValue> _value;

  static CaptureChannel get _channel => CaptureChannel.instance;

  CameraSessionValue get _now => _value.value;

  @override
  ValueListenable<CameraSessionValue> get value => _value;

  Map<String, Object?> _args([Map<String, Object?> more = const {}]) => {
    'id': _id,
    ...more,
  };

  @override
  Future<void> setFrameRateCap(int? fps) async {
    _open();
    await _channel.invoke<void>('cameraCap', _args({'fps': fps}));
    _value.value = _now.copyWith(frameRateCap: fps, replaceFrameRateCap: true);
  }

  // How long a switch waits for the platform to report the new camera's
  // first frame before it stops waiting, so a preview never stays blurred.
  static const Duration _switchWait = Duration(seconds: 2);
  Timer? _switchTimer;

  // The texture holds the old camera's frames until the new camera's
  // first frame, which the platform reports with `firstFrame`; until then
  // the value says it is switching.
  @override
  Future<CameraFacing> switchCamera() async {
    _open();
    final before = _now.facing;
    // The previews hold the frame the user sees before the camera changes.
    await CameraSnapshots.takeAll(this, switching: true);
    _value.value = _now.copyWith(isSwitching: true);
    _switchTimer?.cancel();
    _switchTimer = Timer(_switchWait, _switched);
    try {
      final facing = await _channel.invoke<String>('cameraSwitch', _args());
      if (_now.state == CameraSessionState.closed) return _now.facing;
      if (facing != null) {
        _value.value = _now.copyWith(
          facing: CameraFacing.values.byName(facing),
        );
      }
    } on Object {
      _switched();
      rethrow;
    }
    // No other camera: nothing changes on screen.
    if (_now.facing == before) _switched();
    return _now.facing;
  }

  void _switched() {
    _switchTimer?.cancel();
    _switchTimer = null;
    if ((_now.isSwitching || (_now.awaitingFrames && !_now.isPaused)) &&
        _now.state != CameraSessionState.closed) {
      _value.value = _now.copyWith(isSwitching: false, awaitingFrames: false);
    }
  }

  @override
  Future<void> setZoom(double zoom) async {
    _open();
    final clamped = zoom.clamp(0.0, 1.0);
    await _channel.invoke<void>('cameraZoom', _args({'zoom': clamped}));
    _value.value = _now.copyWith(zoom: clamped);
  }

  @override
  Future<void> focusAt(Offset point) async {
    _open();
    CameraFocus.check(point);
    await _channel.invoke<void>(
      'cameraFocus',
      _args({'x': point.dx, 'y': point.dy}),
    );
  }

  @override
  Future<void> setFlash(CameraFlash flash) async {
    _open();
    await _channel.invoke<void>('cameraFlash', _args({'mode': flash.name}));
    _value.value = _now.copyWith(flash: flash);
  }

  @override
  Future<void> pause() async {
    _open();
    if (_now.isPaused) return;
    if (_now.isRecording) await stopRecording();
    // Hidden, the camera is let go already.
    if (!_hidden) {
      await CameraSnapshots.takeAll(this, switching: false);
      await _channel.invoke<void>('cameraPause', _args());
    }
    _value.value = _now.copyWith(isPaused: true, awaitingFrames: true);
  }

  @override
  Future<void> resume() async {
    _open();
    if (!_now.isPaused) return;
    // Hidden, the camera opens again when the app shows.
    if (_hidden) {
      _value.value = _now.copyWith(isPaused: false);
      return;
    }
    await _channel.invoke<void>('cameraResume', _args());
    _value.value = _now.copyWith(isPaused: false);
    // Waits for the first frame after the resume, as after a switch.
    _switchTimer?.cancel();
    _switchTimer = Timer(_switchWait, _switched);
  }

  @override
  Future<CaptureOutput> capturePhoto({
    required String outputPath,
    bool mirrorFront = false,
  }) async {
    _available();
    final map = await _channel.invoke<Map<Object?, Object?>>(
      'cameraPhoto',
      _args({'output': outputPath, 'mirrorFront': mirrorFront}),
    );
    return _output(map, video: false);
  }

  @override
  Future<void> startRecording({required String outputPath}) async {
    _available();
    if (_now.isRecording) throw const CaptureFailed('already recording');
    await _channel.invoke<void>(
      'cameraRecordStart',
      _args({'output': outputPath}),
    );
    _value.value = _now.copyWith(isRecording: true);
  }

  @override
  Future<CaptureOutput> stopRecording() async {
    _open();
    if (!_now.isRecording) throw const CaptureFailed('not recording');
    try {
      final map = await _channel.invoke<Map<Object?, Object?>>(
        'cameraRecordStop',
        _args(),
      );
      return _output(map, video: true);
    } finally {
      if (_now.state != CameraSessionState.closed) {
        _value.value = _now.copyWith(isRecording: false);
      }
    }
  }

  @override
  Future<void> dispose() async {
    if (_now.state == CameraSessionState.closed) return;
    _closedHere();
    CameraClaim.drop(this);
    await _channel.invoke<void>('cameraClose', _args());
  }

  // --- Platform events ---

  void _closedHere() {
    _switchTimer?.cancel();
    _background.dispose();
    _channel.unlisten(_id);
    if (_now.state != CameraSessionState.closed) {
      _value.value = const CameraSessionValue(state: CameraSessionState.closed);
    }
  }

  void _onEvent(Map<Object?, Object?> event) {
    if (event['type'] == 'camera') _apply(event);
  }

  void _apply(Map<Object?, Object?> map) {
    if (_now.state == CameraSessionState.closed) return;
    final state = switch (map['state']) {
      final String name => CameraSessionState.values.byName(name),
      _ => _now.state,
    };
    if (state == CameraSessionState.closed) return _closedHere();
    final width = map['previewWidth'] as int?;
    final height = map['previewHeight'] as int?;
    _value.value = _now.copyWith(
      state: state,
      textureId: map['textureId'] as int?,
      previewSize: width != null && height != null && width > 0 && height > 0
          ? MediaDimensions(width, height)
          : null,
      quarterTurns: map['quarterTurns'] as int?,
      facing: switch (map['facing']) {
        final String name => CameraFacing.values.byName(name),
        _ => null,
      },
      hasFlash: map['hasFlash'] as bool?,
      canSwitchCamera: map['canSwitch'] as bool?,
      isRecording: state == CameraSessionState.available ? null : false,
    );
    if (map['firstFrame'] == true) _switched();
  }

  // --- Guards ---

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

  static CaptureOutput _output(
    Map<Object?, Object?>? map, {
    required bool video,
  }) {
    if (map == null) throw const CaptureFailed('nothing captured');
    return CaptureOutput(
      path: map['path']! as String,
      size: map['size']! as int,
      duration: Duration(microseconds: map['durationUs'] as int? ?? 0),
      dimensions: MediaDimensions(map['width']! as int, map['height']! as int),
      headerRewritten: video,
    );
  }
}
