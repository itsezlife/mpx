import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:mpx_capture/src/camera/camera_session.dart';

/// Shows a [CameraSession]'s preview: upright, mirrored for a front camera,
/// covering the widget's size by default.
///
/// A camera switch turns the preview over about its vertical axis and
/// blurs it; the frames stay drawn as they were before the switch (the
/// texture still holds the old camera's) until the new camera's first
/// frame, when they take the new camera's orientation and the blur clears.
/// The old frames are never drawn mirrored or turned as the new camera's.
///
/// It only shows: pausing the session when the preview is off screen or
/// covered is the host's call (the library grid's camera slot hands it the
/// signals). [placeholder] stands in while there is no texture (opening,
/// denied, failed, closed, or a fake).
class CameraPreview extends StatefulWidget {
  /// Creates a preview of [session].
  const CameraPreview({
    required this.session,
    this.fit = BoxFit.cover,
    this.placeholder = const SizedBox.expand(),
    super.key,
  });

  /// The session whose camera shows.
  final CameraSession session;

  /// How the frames fill the widget.
  final BoxFit fit;

  /// Shown while there is no texture.
  final Widget placeholder;

  /// How long the preview turns over on a switch.
  static const Duration turnDuration = Duration(milliseconds: 500);

  /// How long the blur takes to clear once the new camera's frames show.
  static const Duration clearDuration = Duration(milliseconds: 120);

  /// How strongly the frames blur during a switch.
  static const double switchBlur = 24;

  @override
  State<CameraPreview> createState() => _CameraPreviewState();
}

class _CameraPreviewState extends State<CameraPreview>
    with TickerProviderStateMixin {
  late final AnimationController _turn;
  // 1 when clear, 0 fully blurred.
  late final AnimationController _clear;

  // How the frames are drawn: the value from before a switch while it runs.
  late CameraSessionValue _drawn;
  bool _switching = false;

  @override
  void initState() {
    super.initState();
    _turn = AnimationController(
      vsync: this,
      duration: CameraPreview.turnDuration,
    );
    _clear = AnimationController(
      vsync: this,
      duration: CameraPreview.clearDuration,
      value: 1,
    );
    _drawn = widget.session.value.value;
    widget.session.value.addListener(_onValue);
  }

  @override
  void didUpdateWidget(CameraPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session)) {
      oldWidget.session.value.removeListener(_onValue);
      widget.session.value.addListener(_onValue);
      _switching = false;
      _drawn = widget.session.value.value;
      _clear.value = 1;
      _turn.value = 0;
    }
  }

  @override
  void dispose() {
    widget.session.value.removeListener(_onValue);
    _turn.dispose();
    _clear.dispose();
    super.dispose();
  }

  void _onValue() {
    final now = widget.session.value.value;
    if (now.isSwitching) {
      if (!_switching) {
        _switching = true;
        _clear.value = 0;
        _turn.forward(from: 0).ignore();
      }
    } else {
      if (_switching) {
        _switching = false;
        _clear.forward(from: 0).ignore();
      }
      _drawn = now;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final now = widget.session.value.value;
    final drawn = _switching ? _drawn : now;
    final textureId = now.textureId;
    final size = drawn.previewSize ?? now.previewSize;
    if (!now.isAvailable || textureId == null || size == null) {
      return widget.placeholder;
    }
    Widget frames = SizedBox(
      width: size.width.toDouble(),
      height: size.height.toDouble(),
      child: Texture(textureId: textureId),
    );
    if (drawn.quarterTurns % 4 != 0) {
      frames = RotatedBox(quarterTurns: drawn.quarterTurns, child: frames);
    }
    if (drawn.mirrored) frames = Transform.flip(flipX: true, child: frames);
    final preview = ClipRect(
      child: FittedBox(fit: widget.fit, child: frames),
    );
    return AnimatedBuilder(
      animation: Listenable.merge([_turn, _clear]),
      builder: (context, child) {
        var shown = child!;
        final sigma = (1 - _clear.value) * CameraPreview.switchBlur;
        if (sigma > 0) {
          shown = ClipRect(
            child: ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
              child: shown,
            ),
          );
        }
        // The first half turns the old frames away to the edge, the second
        // brings the preview back from the other side.
        final t = Curves.ease.transform(_turn.value);
        final angle = (t < 0.5 ? t : t - 1) * math.pi;
        if (_turn.isAnimating && angle != 0) {
          shown = Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..setEntry(3, 2, 0.001)
              ..rotateY(angle),
            child: shown,
          );
        }
        return shown;
      },
      child: preview,
    );
  }
}
