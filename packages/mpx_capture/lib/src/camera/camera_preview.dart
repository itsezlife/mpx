import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:mpx_capture/src/camera/camera_session.dart';
import 'package:mpx_capture/src/camera/camera_snapshots.dart';

/// Shows a [CameraSession]'s preview: upright, mirrored for a front camera,
/// covering the widget's size by default.
///
/// While its frames stop (a pause, until the first frame after the resume)
/// or the camera changes (a switch, until the new camera's first frame), the
/// preview is covered by its last frame as the user saw it: a small
/// snapshot, blurred, which keeps the orientation it had (it never takes the
/// new camera's mirror). A switch turns the preview over about its vertical
/// axis meanwhile. When frames come again the snapshot fades out: 120 ms
/// after a switch, 180 ms after a resume.
///
/// It only shows: pausing the session is the host's call (the library
/// grid's camera slot hands it the signals). [placeholder] stands in while
/// there is no texture (opening, denied, failed, closed, or a fake).
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

  /// How long the snapshot takes to fade once a switched camera's frames
  /// show.
  static const Duration switchClear = Duration(milliseconds: 120);

  /// How long the live preview takes to fade in over the snapshot after a
  /// resume.
  static const Duration resumeClear = Duration(milliseconds: 180);

  @override
  State<CameraPreview> createState() => _CameraPreviewState();
}

// The snapshot's sample width and blur radius, in its own pixels: 100 wide
// with a radius of 3 for a switch, 80 wide with 7 for a pause.
const int _switchSample = 100;
const double _switchRadius = 3;
const int _pauseSample = 80;
const double _pauseRadius = 7;

class _CameraPreviewState extends State<CameraPreview>
    with TickerProviderStateMixin {
  late final AnimationController _turn;
  // 1 when the snapshot is gone, 0 while it covers the preview.
  late final AnimationController _clear;
  final GlobalKey _live = GlobalKey();

  // The value the frames were drawn with before the stop, for a fallback
  // when no snapshot could be taken.
  late CameraSessionValue _drawn;
  bool _waiting = false;
  bool _switch = false;
  ui.Image? _stub;

  @override
  void initState() {
    super.initState();
    _turn = AnimationController(
      vsync: this,
      duration: CameraPreview.turnDuration,
    );
    _clear = AnimationController(vsync: this, value: 1)
      ..addStatusListener((status) {
        if (status.isCompleted) _dropStub();
      });
    _drawn = widget.session.value.value;
    widget.session.value.addListener(_onValue);
    CameraSnapshots.add(widget.session, _take);
  }

  // The frame taken by the session just before it stopped its frames.
  ui.Image? _taken;

  // Called by the session before a pause or a switch: the snapshot is read
  // here, rasterized and awaited, while the texture still holds the frame
  // the user sees.
  Future<void> _take({required bool switching}) async {
    final box = _live.currentContext?.findRenderObject();
    if (box is! RenderRepaintBoundary || !box.hasSize || box.size.isEmpty) {
      return;
    }
    final sample = switching ? _switchSample : _pauseSample;
    try {
      final image = await box.toImage(pixelRatio: sample / box.size.width);
      if (!mounted) return image.dispose();
      _taken?.dispose();
      _taken = image;
    } on Object {
      // No snapshot: the frozen frames stand in.
    }
  }

  // Whether this preview's tickers run (false under an opaque route): a
  // preview not on screen does not animate a switch or a fade, or it would
  // play them when it shows again.
  bool _ticking = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ticking = TickerMode.valuesOf(context).enabled;
    if (ticking == _ticking) return;
    _ticking = ticking;
    if (!ticking) return;
    // Showing again: what ran while hidden is over.
    if (_turn.value != 0) {
      _turn
        ..stop()
        ..value = 0;
    }
    if (!_waiting && _clear.value < 1) _clear.value = 1;
  }

  @override
  void didUpdateWidget(CameraPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session)) {
      oldWidget.session.value.removeListener(_onValue);
      widget.session.value.addListener(_onValue);
      CameraSnapshots.remove(oldWidget.session, _take);
      CameraSnapshots.add(widget.session, _take);
      _waiting = false;
      _drawn = widget.session.value.value;
      _dropStub();
      _clear.value = 1;
      _turn.value = 0;
    }
  }

  @override
  void dispose() {
    widget.session.value.removeListener(_onValue);
    CameraSnapshots.remove(widget.session, _take);
    _taken?.dispose();
    _turn.dispose();
    _clear.dispose();
    _stub?.dispose();
    super.dispose();
  }

  void _dropStub() {
    final stub = _stub;
    if (stub == null) return;
    _stub = null;
    stub.dispose();
    if (mounted) setState(() {});
  }

  // The preview as it stands now, small: read before the value's change is
  // built, so it still has the orientation the user saw.
  ui.Image? _snapshot(int sample) {
    final box = _live.currentContext?.findRenderObject();
    if (box is! RenderRepaintBoundary || !box.hasSize || box.size.isEmpty) {
      return null;
    }
    try {
      return box.toImageSync(pixelRatio: sample / box.size.width);
    } on Object {
      return null;
    }
  }

  void _onValue() {
    final now = widget.session.value.value;
    final stopped = now.isSwitching || now.awaitingFrames;
    if (stopped && !_waiting) {
      _waiting = true;
      _switch = now.isSwitching;
      _stub?.dispose();
      _stub = _taken ?? _snapshot(_switch ? _switchSample : _pauseSample);
      _taken = null;
      _clear.value = 0;
      if (_switch && _ticking) _turn.forward(from: 0).ignore();
    } else if (!stopped && _waiting) {
      _waiting = false;
      if (_ticking) {
        _clear.duration = _switch
            ? CameraPreview.switchClear
            : CameraPreview.resumeClear;
        _clear.forward(from: 0).ignore();
      } else {
        _clear.value = 1;
      }
    }
    if (!stopped) _drawn = now;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final now = widget.session.value.value;
    // With a snapshot over it the preview takes the new camera's
    // orientation at once; without one, it keeps the old until the frames.
    final drawn = _waiting && _stub == null ? _drawn : now;
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
    final live = RepaintBoundary(
      key: _live,
      child: KeyedSubtree(
        key: const ValueKey('mpx-camera-live'),
        child: ClipRect(
          child: FittedBox(fit: widget.fit, child: frames),
        ),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) => AnimatedBuilder(
        animation: Listenable.merge([_turn, _clear]),
        builder: (context, child) {
          var shown = child!;
          final stub = _stub;
          // The first half turns the old picture away to the edge, the
          // second brings it back from the other side.
          final t = Curves.ease.transform(_turn.value);
          final angle = (t < 0.5 ? t : t - 1) * math.pi;
          final turning = _turn.isAnimating && angle != 0;
          if (stub != null && _clear.value < 1) {
            final sample = _switch ? _switchSample : _pauseSample;
            final radius = _switch ? _switchRadius : _pauseRadius;
            // The radius in the snapshot's pixels, at the widget's size.
            final sigma = radius * constraints.maxWidth / sample / 2;
            shown = Stack(
              fit: StackFit.expand,
              children: [
                // While the card turns it is the only layer: the live
                // frames under it (the new camera's, mirrored and shaped
                // differently) would turn with it and show at its edges.
                Offstage(offstage: turning, child: shown),
                Opacity(
                  opacity: 1 - _clear.value,
                  child: ClipRect(
                    child: ImageFiltered(
                      imageFilter: ui.ImageFilter.blur(
                        sigmaX: sigma,
                        sigmaY: sigma,
                        tileMode: TileMode.clamp,
                      ),
                      child: RawImage(
                        key: const ValueKey('mpx-camera-stub'),
                        image: stub,
                        fit: BoxFit.fill,
                        filterQuality: FilterQuality.medium,
                      ),
                    ),
                  ),
                ),
              ],
            );
          } else if (_waiting) {
            // No snapshot: the frozen frames, blurred.
            shown = ClipRect(
              child: ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                child: shown,
              ),
            );
          }
          if (turning) {
            shown = Transform(
              alignment: Alignment.center,
              // The eye stands 4 heights away, so the card's near edge
              // grows only a little as it turns.
              transform: Matrix4.identity()
                ..setEntry(3, 2, 1 / (4 * constraints.maxHeight))
                ..rotateY(angle),
              child: shown,
            );
          }
          return shown;
        },
        child: live,
      ),
    );
  }
}
