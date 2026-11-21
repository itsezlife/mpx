import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';
import 'package:mpx_capture/src/job/capture_job.dart';
import 'package:mpx_capture/src/round/round_video_recorder.dart';
import 'package:mpx_core/mpx_core.dart';

/// Where a [CameraSession] stands.
enum CameraSessionState {
  /// The camera is starting; no frames yet.
  opening,

  /// Frames flow (or would, when paused); captures work.
  available,

  /// The camera is not allowed; the host shows its own state (settings, the
  /// system camera intake).
  denied,

  /// The camera could not be opened or broke while running.
  failed,

  /// Disposed, or taken over by a newer session.
  closed,
}

/// The flash of photos (and the torch while recording).
enum CameraFlash {
  /// Never.
  off,

  /// When the scene is dark (photos); off while recording.
  auto,

  /// Always (photos); the torch while recording.
  on,
}

/// Everything a widget shows of a [CameraSession], as one value.
@immutable
final class CameraSessionValue {
  /// Creates a value.
  const CameraSessionValue({
    this.state = CameraSessionState.opening,
    this.facing = CameraFacing.back,
    this.flash = CameraFlash.off,
    this.isPaused = false,
    this.isRecording = false,
    this.textureId,
    this.previewSize,
    this.quarterTurns = 0,
    this.hasFlash = false,
    this.canSwitchCamera = false,
    this.frameRateCap,
    this.isSwitching = false,
    this.awaitingFrames = false,
    this.zoom = 0,
    this.microphone = MicrophoneAccess.notDetermined,
    this.zoomFactor = 1,
    this.minZoomFactor = 1,
    this.maxZoomFactor = 1,
    this.lenses = const [1],
    this.exposure = 0,
    this.hasExposure = false,
  });

  /// Where the session stands.
  final CameraSessionState state;

  /// The camera in use.
  final CameraFacing facing;

  /// The flash mode.
  final CameraFlash flash;

  /// Whether frames are stopped until a resume.
  final bool isPaused;

  /// Whether a video is being recorded.
  final bool isRecording;

  /// The texture that shows the camera, or null when there is none (before
  /// the first frame, after close, or a fake without one).
  final int? textureId;

  /// The size of the preview frames as the texture holds them.
  final MediaDimensions? previewSize;

  /// Quarter turns clockwise that stand the texture upright.
  final int quarterTurns;

  /// Whether the camera has a flash.
  final bool hasFlash;

  /// Whether another camera is there to switch to.
  final bool canSwitchCamera;

  /// The preview frame-rate cap in frames per second, or null for the
  /// camera's own rate.
  final int? frameRateCap;

  /// Whether the camera is changing: from a switch until the new camera's
  /// first frame. Meanwhile the texture still holds the old camera's last
  /// frames, while [facing] and [quarterTurns] already name the new one, so
  /// a preview draws the frames as it drew them before the switch.
  final bool isSwitching;

  /// Whether the frames stopped: from a pause until the first frame after
  /// the resume. The texture holds the last frame meanwhile.
  final bool awaitingFrames;

  /// The zoom, 0 (the widest) to 1 (the camera's longest), linear.
  final double zoom;

  /// Whether a recording may take sound: the platform's microphone access.
  final MicrophoneAccess microphone;

  /// The zoom as a factor of the main lens's view (1x; 0.5 on an ultra
  /// wide lens). [zoom] is the same zoom on a 0..1 scale over
  /// [minZoomFactor]..[maxZoomFactor] (`CameraZoom`).
  final double zoomFactor;

  /// The widest factor the camera reaches.
  final double minZoomFactor;

  /// The longest factor the camera reaches.
  final double maxZoomFactor;

  /// The factors of the camera's lenses (or preset steps), ascending; 1
  /// among them.
  final List<double> lenses;

  /// The exposure bias, -1 (darkest) to 1 (brightest); 0 is the camera's
  /// own.
  final double exposure;

  /// Whether the camera takes an exposure bias.
  final bool hasExposure;

  /// Whether the preview is drawn mirrored, as a front camera's is. The
  /// frames and the captures are not mirrored; only the preview is.
  bool get mirrored => facing == CameraFacing.front;

  /// Whether captures work now.
  bool get isAvailable => state == CameraSessionState.available;

  /// A copy with the given fields replaced; [frameRateCap] is replaced only
  /// when [replaceFrameRateCap] is true (so null can be set).
  CameraSessionValue copyWith({
    CameraSessionState? state,
    CameraFacing? facing,
    CameraFlash? flash,
    bool? isPaused,
    bool? isRecording,
    int? textureId,
    MediaDimensions? previewSize,
    int? quarterTurns,
    bool? hasFlash,
    bool? canSwitchCamera,
    int? frameRateCap,
    bool replaceFrameRateCap = false,
    bool? isSwitching,
    bool? awaitingFrames,
    double? zoom,
    MicrophoneAccess? microphone,
    double? zoomFactor,
    double? minZoomFactor,
    double? maxZoomFactor,
    List<double>? lenses,
    double? exposure,
    bool? hasExposure,
  }) => CameraSessionValue(
    state: state ?? this.state,
    facing: facing ?? this.facing,
    flash: flash ?? this.flash,
    isPaused: isPaused ?? this.isPaused,
    isRecording: isRecording ?? this.isRecording,
    textureId: textureId ?? this.textureId,
    previewSize: previewSize ?? this.previewSize,
    quarterTurns: quarterTurns ?? this.quarterTurns,
    hasFlash: hasFlash ?? this.hasFlash,
    canSwitchCamera: canSwitchCamera ?? this.canSwitchCamera,
    frameRateCap: replaceFrameRateCap ? frameRateCap : this.frameRateCap,
    isSwitching: isSwitching ?? this.isSwitching,
    awaitingFrames: awaitingFrames ?? this.awaitingFrames,
    zoom: zoom ?? this.zoom,
    microphone: microphone ?? this.microphone,
    zoomFactor: zoomFactor ?? this.zoomFactor,
    minZoomFactor: minZoomFactor ?? this.minZoomFactor,
    maxZoomFactor: maxZoomFactor ?? this.maxZoomFactor,
    lenses: lenses ?? this.lenses,
    exposure: exposure ?? this.exposure,
    hasExposure: hasExposure ?? this.hasExposure,
  );

  @override
  bool operator ==(Object other) =>
      other is CameraSessionValue &&
      other.state == state &&
      other.facing == facing &&
      other.flash == flash &&
      other.isPaused == isPaused &&
      other.isRecording == isRecording &&
      other.textureId == textureId &&
      other.previewSize == previewSize &&
      other.quarterTurns == quarterTurns &&
      other.hasFlash == hasFlash &&
      other.canSwitchCamera == canSwitchCamera &&
      other.frameRateCap == frameRateCap &&
      other.isSwitching == isSwitching &&
      other.awaitingFrames == awaitingFrames &&
      other.zoom == zoom &&
      other.microphone == microphone &&
      other.zoomFactor == zoomFactor &&
      other.minZoomFactor == minZoomFactor &&
      other.maxZoomFactor == maxZoomFactor &&
      listEquals(other.lenses, lenses) &&
      other.exposure == exposure &&
      other.hasExposure == hasExposure;

  @override
  int get hashCode => Object.hashAll([
    state,
    facing,
    flash,
    isPaused,
    isRecording,
    textureId,
    previewSize,
    quarterTurns,
    hasFlash,
    canSwitchCamera,
    frameRateCap,
    isSwitching,
    awaitingFrames,
    zoom,
    microphone,
    zoomFactor,
    minZoomFactor,
    maxZoomFactor,
    Object.hashAll(lenses),
    exposure,
    hasExposure,
  ]);

  @override
  String toString() =>
      'CameraSessionValue(${state.name}, ${facing.name}, flash ${flash.name}'
      '${isPaused ? ', paused' : ''}${isRecording ? ', recording' : ''}'
      '${frameRateCap == null ? '' : ', cap $frameRateCap fps'}'
      '${isSwitching ? ', switching' : ''})';
}

/// A live camera: a preview texture, photos and videos, a camera switch, a
/// flash, pause and resume, and a frame-rate cap for small previews.
///
/// The session lives apart from the widgets that show it: a small preview
/// (the library grid's camera slot) and the capture surface show the same
/// running session, so moving between them restarts nothing. The host
/// disposes it.
///
/// ## Contract
///
/// - [value] notifies on every change. Without camera access the state is
///   [CameraSessionState.denied]; a camera that cannot open is
///   [CameraSessionState.failed].
/// - [capturePhoto] writes a JPEG into the output path and completes with
///   its facts; [startRecording] and [stopRecording] write an MP4 (H.264,
///   AAC when the microphone is allowed). Both fail with `CaptureFailed`
///   unless the session is available, and [stopRecording] unless it
///   records. Captures are not mirrored, except a front camera's photo
///   taken with `mirrorFront`.
/// - [pause] stops frames until [resume]; a pause stops a recording first.
/// - A newer session from the same `CameraSessions` takes the camera over:
///   this one turns [CameraSessionState.closed]. Every call on a closed
///   session fails with `CaptureFailed`, except [dispose], which is
///   idempotent.
abstract interface class CameraSession {
  /// What widgets show; notifies on every change.
  ValueListenable<CameraSessionValue> get value;

  /// Caps the preview at [fps] frames per second (30 for a small preview),
  /// or lifts the cap with null. No restart.
  Future<void> setFrameRateCap(int? fps);

  /// Moves to the other camera; completes with the camera in use (the same
  /// one when there is no other).
  Future<CameraFacing> switchCamera();

  /// Sets the flash mode.
  Future<void> setFlash(CameraFlash flash);

  /// Zooms to [zoom], 0 (the widest) to 1 (the longest the camera has),
  /// linear; clamped.
  Future<void> setZoom(double zoom);

  /// Zooms to [factor] of the main lens's view, clamped to
  /// [CameraSessionValue.minZoomFactor]..[CameraSessionValue.maxZoomFactor];
  /// past a lens's factor the camera moves to that lens.
  Future<void> setZoomFactor(double factor);

  /// Keeps the camera ready to record until [releaseVideo]: a recording then
  /// starts on the running session, with no pause of the preview. Holding
  /// it costs an encoder's setup; a full camera page holds it, a small
  /// preview does not. Idempotent.
  Future<void> prepareVideo();

  /// Lets go of [prepareVideo]'s readiness once no recording runs.
  /// Idempotent.
  Future<void> releaseVideo();

  /// Sets the exposure bias, -1 (darkest) to 1 (brightest), clamped; a
  /// camera without one ([CameraSessionValue.hasExposure] false) keeps 0.
  Future<void> setExposure(double value);

  /// Focuses (and meters) at [point] of the preview as it shows, from
  /// (0, 0) at its top left to (1, 1) at its bottom right. Throws an
  /// [ArgumentError] for a point outside.
  Future<void> focusAt(Offset point);

  /// Asks for microphone access when it is not granted, and completes with
  /// the access after the answer (at once when granted, or when the
  /// platform will not ask again). [CameraSessionValue.microphone] follows.
  /// A recording started after a grant takes sound.
  Future<MicrophoneAccess> requestMicrophone();

  /// Stops frames until [resume].
  Future<void> pause();

  /// Starts frames again after [pause].
  Future<void> resume();

  /// Takes a photo into [outputPath] (a JPEG; an existing file is replaced).
  /// With [mirrorFront] a front camera's photo is saved mirrored, as its
  /// preview shows it; a back camera's never is.
  Future<CaptureOutput> capturePhoto({
    required String outputPath,
    bool mirrorFront = false,
  });

  /// Starts recording a video into [outputPath] (an MP4).
  Future<void> startRecording({required String outputPath});

  /// Finishes the recording; completes with the file.
  Future<CaptureOutput> stopRecording();

  /// Stops the camera and frees the texture. Idempotent.
  Future<void> dispose();
}

/// Opens [CameraSession]s, one at a time per process: opening another takes
/// the camera over from the previous one, which closes.
///
/// Implementations: `PlatformCameraSessions` (CameraX on Android,
/// AVCaptureSession on iOS and macOS) and `FakeCameraSessions` in
/// `testing.dart`; both meet `CameraSessionContract`.
abstract interface class CameraSessions {
  /// Opens [facing] (the other camera when it is missing), asking for camera
  /// access (and microphone access with [audio]) when not yet asked.
  ///
  /// Completes once the session is available, denied or failed; it never
  /// throws for a missing permission or camera.
  Future<CameraSession> open({
    CameraFacing facing = CameraFacing.back,
    int? frameRateCap,
    bool audio = true,
  });
}

/// The point checks of [CameraSession.focusAt].
abstract final class CameraFocus {
  /// Throws an [ArgumentError] unless [point] lies in the unit square.
  static void check(Offset point) {
    if (point.dx < 0 || point.dx > 1 || point.dy < 0 || point.dy > 1) {
      throw ArgumentError.value(point, 'point', 'outside the preview');
    }
  }
}

/// The platform's microphone access, as a camera session reports it.
enum MicrophoneAccess {
  /// Granted: recordings take sound.
  granted,

  /// Not asked yet (on Android: not granted, and not refused since the app
  /// started); [CameraSession.requestMicrophone] shows the platform's prompt.
  notDetermined,

  /// Refused; asking again may show nothing (the platform's settings are the
  /// way back).
  denied,
}

/// The two zoom scales of a [CameraSessionValue]: a 0..1 zoom moves the
/// crop's width evenly between the widest and the longest factor (as a
/// slider feels even), a factor is the lens's magnification.
abstract final class CameraZoom {
  /// The factor of [zoom] (0..1) between [min] and [max].
  static double factorOf(double zoom, double min, double max) {
    if (max <= min) return min;
    final z = zoom.clamp(0.0, 1.0);
    return 1 / (1 / min + z * (1 / max - 1 / min));
  }

  /// The 0..1 zoom of [factor] between [min] and [max].
  static double zoomOf(double factor, double min, double max) {
    if (max <= min) return 0;
    final f = factor.clamp(min, max);
    return ((1 / f - 1 / min) / (1 / max - 1 / min)).clamp(0.0, 1.0);
  }
}
