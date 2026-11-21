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
    this.microphone = MicrophoneAccess.granted,
    this.minZoomFactor = 1,
    this.maxZoomFactor = 10,
    this.lenses = const [1, 2],
    this.hasExposure = true,
    this.photoTakes = Duration.zero,
    this.recordingStartTakes = Duration.zero,
    this.microphoneOnRequest = MicrophoneAccess.granted,
    FakeCamera? camera,
  }) : camera = camera ?? FakeCamera();

  /// The zoom factors the cameras reach.
  final double minZoomFactor;

  /// See [minZoomFactor].
  final double maxZoomFactor;

  /// The lenses' factors.
  final List<double> lenses;

  /// Whether the cameras take an exposure bias.
  final bool hasExposure;

  /// How long a photo takes before it completes.
  final Duration photoTakes;

  /// How long a recording takes to start.
  final Duration recordingStartTakes;

  /// The microphone access sessions open with.
  MicrophoneAccess microphone;

  /// What a microphone request answers when not granted.
  MicrophoneAccess microphoneOnRequest;

  /// How many microphone requests asked (not counting granted ones).
  int microphoneRequests = 0;

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
        microphone: microphone,
        zoomFactor: 1,
        zoom: CameraZoom.zoomOf(1, minZoomFactor, maxZoomFactor),
        minZoomFactor: minZoomFactor,
        maxZoomFactor: maxZoomFactor,
        lenses: lenses,
        hasExposure: hasExposure,
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

  bool _switchCalled = false;

  /// How many switches were made (not counting ignored ones).
  int switches = 0;

  @override
  Future<CameraFacing> switchCamera() async {
    _open();
    if (!_now.canSwitchCamera) return _now.facing;
    // Ignored while a switch runs, until the new camera's first frame.
    if (_switchCalled || _now.isSwitching) return _now.facing;
    _switchCalled = true;
    try {
      await CameraSnapshots.takeAll(this, switching: true);
    } finally {
      _switchCalled = false;
    }
    switches++;
    final next = _now.facing == CameraFacing.front
        ? CameraFacing.back
        : CameraFacing.front;
    _value.value = _now.copyWith(
      facing: next,
      isSwitching: _owner.holdsSwitchFrames,
      zoomFactor: 1,
      zoom: CameraZoom.zoomOf(1, _now.minZoomFactor, _now.maxZoomFactor),
      exposure: 0,
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
  Future<MicrophoneAccess> requestMicrophone() async {
    _open();
    if (_now.microphone == MicrophoneAccess.granted) return _now.microphone;
    _owner.microphoneRequests++;
    _owner.microphone = _owner.microphoneOnRequest;
    _value.value = _now.copyWith(microphone: _owner.microphoneOnRequest);
    return _now.microphone;
  }

  @override
  Future<void> setZoom(double zoom) async {
    _open();
    final z = zoom.clamp(0.0, 1.0);
    _value.value = _now.copyWith(
      zoom: z,
      zoomFactor: CameraZoom.factorOf(
        z,
        _now.minZoomFactor,
        _now.maxZoomFactor,
      ),
    );
  }

  @override
  Future<void> setZoomFactor(double factor) async {
    _open();
    final now = _now;
    final f = factor.clamp(now.minZoomFactor, now.maxZoomFactor);
    _value.value = now.copyWith(
      zoomFactor: f,
      zoom: CameraZoom.zoomOf(f, now.minZoomFactor, now.maxZoomFactor),
    );
  }

  /// Whether the session is kept ready to record.
  bool videoPrepared = false;

  @override
  Future<void> prepareVideo() async {
    _open();
    videoPrepared = true;
  }

  @override
  Future<void> releaseVideo() async {
    videoPrepared = false;
  }

  @override
  Future<void> setExposure(double value) async {
    _open();
    if (!_now.hasExposure) return;
    _value.value = _now.copyWith(exposure: value.clamp(-1.0, 1.0));
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
    if (_owner.photoTakes > Duration.zero) {
      await Future<void>.delayed(_owner.photoTakes);
    }
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
    if (_owner.recordingStartTakes > Duration.zero) {
      await Future<void>.delayed(_owner.recordingStartTakes);
    }
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
    // A small picture beside it, as a platform writes the first frame.
    final poster = '$path.poster.jpg';
    File(poster).writeAsBytesSync(_posterBytes);
    _value.value = _now.copyWith(isRecording: false);
    return CaptureOutput(
      path: path,
      size: bytes.length,
      duration: _recording.elapsed,
      dimensions: const MediaDimensions(1080, 1920),
      headerRewritten: true,
      posterPath: poster,
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

// A 2 x 2 PNG: a stand-in poster any image codec reads.
final Uint8List _posterBytes = Uint8List.fromList(const [
  137,
  80,
  78,
  71,
  13,
  10,
  26,
  10,
  0,
  0,
  0,
  13,
  73,
  72,
  68,
  82,
  0,
  0,
  0,
  2,
  0,
  0,
  0,
  2,
  8,
  2,
  0,
  0,
  0,
  253,
  212,
  154,
  115,
  0,
  0,
  0,
  16,
  73,
  68,
  65,
  84,
  120,
  156,
  99,
  56,
  81,
  161,
  1,
  68,
  12,
  16,
  10,
  0,
  41,
  238,
  5,
  161,
  140,
  9,
  206,
  136,
  0,
  0,
  0,
  0,
  73,
  69,
  78,
  68,
  174,
  66,
  96,
  130,
]);
