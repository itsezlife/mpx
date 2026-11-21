import 'package:flutter/foundation.dart';
import 'package:mpx_capture/src/camera/camera_session.dart';

/// How zoom gestures and controls measure the zoom.
enum CaptureZoomScale {
  /// On the 0..1 scale ([CameraSessionValue.zoom]): a pinch adds its spread
  /// over 100 px (past a slop), a finger dragged above the held shutter sets
  /// the distance over 200, and coming back down returns to the widest.
  linear,

  /// As a lens factor ([CameraSessionValue.zoomFactor]): a pinch adds
  /// (scale − 1) × 1.25 (twice that above 2×); while a hold records, a drag
  /// up sets 1 + the distance over 60. Both stop at the policy's
  /// [CaptureSurfacePolicy.maxZoomFactor].
  factor,
}

/// The zoom control the surface shows.
enum CaptureZoomControl {
  /// A slider with minus and plus that shows while the zoom is used.
  slider,

  /// A pill of lens buttons (0.5×, 1×, 2×, …) that stays while the camera
  /// has more than one; a horizontal drag on it zooms between them.
  lenses,
}

/// The mark a focus tap leaves.
enum CaptureFocusMark {
  /// A ring that closes in on the point and fades.
  ring,

  /// A square crosshair at the point, with an exposure handle beside it: a
  /// vertical drag on the picture then sets the exposure.
  crosshair,
}

/// How the recording time shows.
enum CaptureTimerStyle {
  /// `m:ss` in a dark pill with a red dot.
  pill,

  /// `MM:SS` (`HH:MM:SS` past an hour) in a red rounded box.
  redBox,
}

/// The shutter's look.
enum CaptureShutterStyle {
  /// A ring round a white disc that turns into a red dot while recording;
  /// it grows a little while pressed.
  dot,

  /// A ring round a disc, white for photos and red for videos, that turns
  /// into a small red rounded square while recording.
  square,
}

/// What the side controls do while a recording runs.
enum CaptureRecordingChrome {
  /// The flash and the switch slide 30 px out to their edge and fade.
  slideAside,

  /// Close, flash, switch and the mode control fade out.
  fade,
}

/// The capture surface's behaviour on a platform: the shutter's timing and
/// modes, the zoom, focus, the timer and what a recording hides.
///
/// [$Android] and [$IOS] follow each platform's reference camera;
/// [forPlatform] picks one.
@immutable
final class CaptureSurfacePolicy {
  /// Creates a policy.
  const CaptureSurfacePolicy({
    required this.holdToRecord,
    required this.modeControl,
    required this.flashModes,
    required this.timer,
    required this.zoomScale,
    required this.zoomControl,
    required this.maxZoomFactor,
    required this.focus,
    required this.shutter,
    required this.recordingChrome,
    required this.zoomResetsAfterEveryShot,
    required this.zoomResetAfterRecording,
    required this.photoBlink,
    required this.resultsStrip,
    required this.locksWhileSwitching,
  });

  /// The Android reference camera: tap for a photo, hold 800 ms for a
  /// video; flash off → auto → on; a zoom slider; a closing focus ring; the
  /// zoom back to the widest after every shot.
  static const CaptureSurfacePolicy $Android = CaptureSurfacePolicy(
    holdToRecord: Duration(milliseconds: 800),
    modeControl: false,
    flashModes: [CameraFlash.off, CameraFlash.auto, CameraFlash.on],
    timer: CaptureTimerStyle.pill,
    zoomScale: CaptureZoomScale.linear,
    zoomControl: CaptureZoomControl.slider,
    maxZoomFactor: double.infinity,
    focus: CaptureFocusMark.ring,
    shutter: CaptureShutterStyle.dot,
    recordingChrome: CaptureRecordingChrome.slideAside,
    zoomResetsAfterEveryShot: true,
    zoomResetAfterRecording: null,
    photoBlink: false,
    resultsStrip: false,
    locksWhileSwitching: false,
  );

  /// The iOS reference camera: a Video / Photo mode control; in photo mode
  /// a 250 ms hold switches to video and records until release; flash off
  /// ↔ auto; lens buttons and factor zoom up to 8×; a focus crosshair with
  /// exposure; the shutter turns into a red square while recording; the
  /// zoom back to 1× 0.3 s after a recording; the preview blinks on a
  /// photo; the shots so far in a strip.
  static const CaptureSurfacePolicy $IOS = CaptureSurfacePolicy(
    holdToRecord: Duration(milliseconds: 250),
    modeControl: true,
    flashModes: [CameraFlash.off, CameraFlash.auto],
    timer: CaptureTimerStyle.redBox,
    zoomScale: CaptureZoomScale.factor,
    zoomControl: CaptureZoomControl.lenses,
    maxZoomFactor: 8,
    focus: CaptureFocusMark.crosshair,
    shutter: CaptureShutterStyle.square,
    recordingChrome: CaptureRecordingChrome.fade,
    zoomResetsAfterEveryShot: false,
    zoomResetAfterRecording: Duration(milliseconds: 300),
    photoBlink: true,
    resultsStrip: true,
    locksWhileSwitching: true,
  );

  /// The policy of [platform]: [$IOS] on iOS and macOS, [$Android]
  /// elsewhere.
  static CaptureSurfacePolicy forPlatform(TargetPlatform platform) =>
      switch (platform) {
        TargetPlatform.iOS || TargetPlatform.macOS => $IOS,
        _ => $Android,
      };

  /// How long the shutter is held before a video records.
  final Duration holdToRecord;

  /// Whether a Video / Photo mode control shows when both kinds are
  /// allowed (and the labels name the modes).
  final bool modeControl;

  /// The flash modes the flash button cycles through, in order.
  final List<CameraFlash> flashModes;

  /// How the recording time shows.
  final CaptureTimerStyle timer;

  /// How zoom gestures measure the zoom.
  final CaptureZoomScale zoomScale;

  /// The zoom control.
  final CaptureZoomControl zoomControl;

  /// The longest factor the gestures and lenses go to (the camera's own
  /// maximum caps it too).
  final double maxZoomFactor;

  /// The focus tap's mark.
  final CaptureFocusMark focus;

  /// The shutter's look.
  final CaptureShutterStyle shutter;

  /// What the side controls do while recording.
  final CaptureRecordingChrome recordingChrome;

  /// Whether the zoom returns to the widest after every shot.
  final bool zoomResetsAfterEveryShot;

  /// How long after a recording stops the zoom returns to 1×; null for
  /// never.
  final Duration? zoomResetAfterRecording;

  /// Whether the preview blinks dark as a photo is taken.
  final bool photoBlink;

  /// Whether the shots taken so far show in a strip above the shutter.
  final bool resultsStrip;

  /// Whether every control ignores touches while the camera switches (until
  /// the new camera's first frame); otherwise only the switch does.
  final bool locksWhileSwitching;
}
