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
      other.frameRateCap == frameRateCap;

  @override
  int get hashCode => Object.hash(
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
  );

  @override
  String toString() =>
      'CameraSessionValue(${state.name}, ${facing.name}, flash ${flash.name}'
      '${isPaused ? ', paused' : ''}${isRecording ? ', recording' : ''}'
      '${frameRateCap == null ? '' : ', cap $frameRateCap fps'})';
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
///   records. Captures are never mirrored.
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

  /// Stops frames until [resume].
  Future<void> pause();

  /// Starts frames again after [pause].
  Future<void> resume();

  /// Takes a photo into [outputPath] (a JPEG; an existing file is replaced).
  Future<CaptureOutput> capturePhoto({required String outputPath});

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
