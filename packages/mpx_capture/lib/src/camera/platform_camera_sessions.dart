import 'package:flutter/foundation.dart';
import 'package:mpx_capture/src/camera/camera_session.dart';
import 'package:mpx_capture/src/job/capture_job.dart';
import 'package:mpx_capture/src/platform/capture_channel.dart';
import 'package:mpx_capture/src/round/round_video_recorder.dart';
import 'package:mpx_core/mpx_core.dart';

/// The [CameraSessions] over the platform cameras: CameraX (preview,
/// image capture and video capture) on Android, AVCaptureSession (a video
/// data output into a Flutter texture, a photo output, an asset writer) on
/// iOS and macOS. iOS records without sound while a call is active.
///
/// One session per process: opening another closes the one before.
final class PlatformCameraSessions implements CameraSessions {
  /// Creates the opener; it holds nothing until [open].
  const PlatformCameraSessions();

  static _PlatformCameraSession? _current;

  static CaptureChannel get _channel => CaptureChannel.instance;

  @override
  Future<CameraSession> open({
    CameraFacing facing = CameraFacing.back,
    int? frameRateCap,
    bool audio = true,
  }) async {
    final previous = _current;
    _current = null;
    previous?._closedHere();
    final id = _channel.nextJobId();
    final session = _PlatformCameraSession(
      id,
      CameraSessionValue(facing: facing, frameRateCap: frameRateCap),
    );
    _current = session;
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
    : _value = ValueNotifier(initial);

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

  @override
  Future<CameraFacing> switchCamera() async {
    _open();
    final facing = await _channel.invoke<String>('cameraSwitch', _args());
    if (facing != null) {
      _value.value = _now.copyWith(facing: CameraFacing.values.byName(facing));
    }
    return _now.facing;
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
    await _channel.invoke<void>('cameraPause', _args());
    _value.value = _now.copyWith(isPaused: true);
  }

  @override
  Future<void> resume() async {
    _open();
    if (!_now.isPaused) return;
    await _channel.invoke<void>('cameraResume', _args());
    _value.value = _now.copyWith(isPaused: false);
  }

  @override
  Future<CaptureOutput> capturePhoto({required String outputPath}) async {
    _available();
    final map = await _channel.invoke<Map<Object?, Object?>>(
      'cameraPhoto',
      _args({'output': outputPath}),
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
    if (identical(PlatformCameraSessions._current, this)) {
      PlatformCameraSessions._current = null;
    }
    await _channel.invoke<void>('cameraClose', _args());
  }

  // --- Platform events ---

  void _closedHere() {
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
