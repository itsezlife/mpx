import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:mpx_capture/src/camera/camera_preview.dart';
import 'package:mpx_capture/src/camera/camera_session.dart';
import 'package:mpx_capture/src/job/capture_job.dart';

/// The small live preview of a [CameraSession] for a grid's camera slot.
///
/// It caps the session at [frameRateCap] (30 fps) while it shows, pauses
/// the session while [paused] (the grid's viewer covers it, or its page is
/// inactive; scrolling it away is no reason: a pause closes the camera)
/// and resumes it after, and shows [deniedBuilder]'s pill when the
/// session is denied. [onUnavailable] hears when the session is denied or
/// failed, so the host can fall back to the system camera. A tap expands
/// into the capture surface with `CameraCaptureSurface.show(from: ...)`,
/// which keeps the same session.
class CameraSlotPreview extends StatefulWidget {
  /// Creates the preview of [session].
  const CameraSlotPreview({
    required this.session,
    required this.paused,
    this.frameRateCap = 30,
    this.deniedBuilder,
    this.onUnavailable,
    this.placeholder = const SizedBox.expand(),
    super.key,
  });

  /// The running session.
  final CameraSession session;

  /// Whether the preview should stop its frames now.
  final bool paused;

  /// The preview's frame-rate cap while it shows.
  final int? frameRateCap;

  /// Builds what shows over the slot when camera access is denied (an
  /// "allow access" pill); nothing when null.
  final WidgetBuilder? deniedBuilder;

  /// Called once when the session turns denied or failed.
  final ValueChanged<CameraSessionState>? onUnavailable;

  /// Shown while there is no frame.
  final Widget placeholder;

  @override
  State<CameraSlotPreview> createState() => _CameraSlotPreviewState();
}

class _CameraSlotPreviewState extends State<CameraSlotPreview> {
  CameraSessionState? _told;

  @override
  void initState() {
    super.initState();
    widget.session.value.addListener(_onValue);
    _apply(capping: true);
    _onValue();
  }

  @override
  void didUpdateWidget(CameraSlotPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session)) {
      oldWidget.session.value.removeListener(_onValue);
      widget.session.value.addListener(_onValue);
      _apply(capping: true);
    } else if (oldWidget.paused != widget.paused ||
        oldWidget.frameRateCap != widget.frameRateCap) {
      _apply(capping: oldWidget.frameRateCap != widget.frameRateCap);
    }
  }

  @override
  void dispose() {
    widget.session.value.removeListener(_onValue);
    super.dispose();
  }

  void _onValue() {
    final state = widget.session.value.value.state;
    if ((state == CameraSessionState.denied ||
            state == CameraSessionState.failed) &&
        _told != state) {
      _told = state;
      widget.onUnavailable?.call(state);
    }
  }

  // After the frame: the session's listeners include widgets of this build.
  void _apply({required bool capping}) {
    final session = widget.session;
    final paused = widget.paused;
    final cap = widget.frameRateCap;
    scheduleMicrotask(() async {
      final value = session.value.value;
      if (value.state == CameraSessionState.closed) return;
      try {
        if (capping && value.frameRateCap != cap) {
          await session.setFrameRateCap(cap);
        }
        if (paused && !value.isPaused) {
          await session.pause();
        } else if (!paused && value.isPaused) {
          await session.resume();
        }
      } on CaptureException {
        // The session closed or broke meanwhile; its state says so.
      }
    });
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<CameraSessionValue>(
        valueListenable: widget.session.value,
        builder: (context, value, _) => Stack(
          fit: StackFit.expand,
          children: [
            CameraPreview(
              session: widget.session,
              placeholder: widget.placeholder,
            ),
            if (value.state == CameraSessionState.denied)
              ?widget.deniedBuilder?.call(context),
          ],
        ),
      );
}
