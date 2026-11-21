import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:mpx_capture/src/cache/capture_cache.dart';
import 'package:mpx_capture/src/camera/camera_preview.dart';
import 'package:mpx_capture/src/camera/camera_session.dart';
import 'package:mpx_capture/src/camera/capture_surface_parts.dart';
import 'package:mpx_capture/src/camera/capture_surface_policy.dart';
import 'package:mpx_capture/src/job/capture_job.dart';
import 'package:mpx_core/mpx_core.dart';

/// What the capture surface offers to take.
enum CaptureKinds {
  /// Photos only: the shutter takes a photo.
  photo,

  /// Videos only: a tap starts and stops a recording, a hold records while
  /// held.
  video,

  /// Both: a tap takes a photo, a hold records a video.
  photoAndVideo;

  /// Whether photos are offered.
  bool get photos => this != video;

  /// Whether videos are offered.
  bool get videos => this != photo;
}

/// Why the shutter did not record a video.
enum CaptureVideoRefusal {
  /// The surface takes photos only ([CaptureKinds.photo]).
  notAllowed,

  /// The microphone is refused (the platform's prompt was declined, or will
  /// not show again).
  microphone,
}

/// The host's words for the capture surface's controls, read by screen
/// readers.
@immutable
final class CaptureSurfaceLabels {
  /// Creates the labels.
  const CaptureSurfaceLabels({
    required this.close,
    required this.shutter,
    required this.switchCamera,
    required this.flash,
    this.videoMode,
    this.photoMode,
    this.shotsCount,
  });

  /// The close button.
  final String close;

  /// The shutter.
  final String shutter;

  /// The camera switch.
  final String switchCamera;

  /// The flash button.
  final String flash;

  /// The video mode's name in a mode control; with [photoMode], a policy
  /// with `modeControl` shows one. Null for none.
  final String? videoMode;

  /// The photo mode's name in a mode control.
  final String? photoMode;

  /// The shots counter's text for so many photos and videos ("3 PHOTOS",
  /// "2 VIDEOS", "5 MEDIA" in the host's plurals); null for no counter.
  final String Function(int photos, int videos)? shotsCount;
}

/// What the capture surface took.
@immutable
final class CameraShot {
  /// Describes a shot.
  const CameraShot({required this.isVideo, required this.output, this.key});

  /// Whether it is a video (else a photo).
  final bool isVideo;

  /// The file's facts. When [key] is set the file has moved into the bytes
  /// store and [CaptureOutput.path] no longer exists.
  final CaptureOutput output;

  /// The local media key the bytes resolve under, when the surface was given
  /// a [CaptureCache].
  final MediaKey$Local? key;

  @override
  String toString() =>
      'CameraShot(${isVideo ? 'video' : 'photo'}, ${key ?? output.path})';
}

/// The minimal full-screen camera over a running [CameraSession]: the
/// preview, a shutter (tap for a photo, hold for a video, as [kinds]
/// allows), a camera switch, a flash button and a close button. No modes
/// strip, zoom or second camera.
///
/// It takes the session over from wherever it showed (a small preview) and
/// gives it back without a restart: on show it lifts the session's
/// frame-rate cap, and on close it restores the cap it found. It never
/// disposes the session.
///
/// A capture is written into [outputDirectory]; with a [cache] it then
/// moves into the bytes store under a fresh `MediaKey.local`. Either way
/// [onCaptured] gets it; the surface stays open for more until the host
/// closes it.
class CameraCaptureSurface extends StatefulWidget {
  /// Creates the surface.
  const CameraCaptureSurface({
    required this.session,
    required this.labels,
    required this.outputDirectory,
    required this.onCaptured,
    required this.onClose,
    this.kinds = CaptureKinds.photoAndVideo,
    this.cache,
    this.expandFrom,
    this.expansion,
    this.controlsReveal,
    this.mirrorFrontPhotos = true,
    this.onVideoRefused,
    this.videoNeedsMicrophone = true,
    this.policy = CaptureSurfacePolicy.$Android,
    this.resultBuilder,
    this.onShotRemoved,
    this.shots,
    this.onShotsTap,
    this.shotOrder,
    this.onShotToggle,
    this.shotSelection,
    super.key,
  });

  /// Shows the surface over the app as a route; completes when it closes.
  /// [onCaptured] runs for each shot; the route pops on close. With [from]
  /// (the camera slot's rectangle, global) it expands from there over
  /// [transition] (350 ms), else it fades in.
  static Future<void> show(
    BuildContext context, {
    required CameraSession session,
    required CaptureSurfaceLabels labels,
    required String outputDirectory,
    required ValueChanged<CameraShot> onCaptured,
    CaptureKinds kinds = CaptureKinds.photoAndVideo,
    CaptureCache? cache,
    Rect? from,
    bool mirrorFrontPhotos = true,
    ValueChanged<CaptureVideoRefusal>? onVideoRefused,
    bool videoNeedsMicrophone = true,
    CaptureSurfacePolicy policy = CaptureSurfacePolicy.$Android,
    Widget Function(BuildContext context, CameraShot shot)? resultBuilder,
    ValueChanged<CameraShot>? onShotRemoved,
    ValueListenable<List<CameraShot>>? shots,
    VoidCallback? onShotsTap,
    int? Function(CameraShot shot)? shotOrder,
    ValueChanged<CameraShot>? onShotToggle,
    Listenable? shotSelection,
    Duration transition = const Duration(milliseconds: 350),
    Duration closeTransition = const Duration(milliseconds: 220),
  }) async {
    // One surface at a time per session: a second tap while one opens or
    // shows does nothing (the reference ignores the camera cell while its
    // camera opens or is open).
    if (!_shown.add(session)) return;
    try {
      await // The preview grows from the slot to the screen over [transition] on
      // an ease curve (back over [closeTransition], the same curve in
      // time), and the controls, laid out at the whole screen, fade with it.
      Navigator.of(context).push<void>(
        PageRouteBuilder<void>(
          transitionDuration: transition,
          reverseTransitionDuration: closeTransition,
          pageBuilder: (context, animation, _) {
            final progress = _EasedInTime(animation);
            return CameraCaptureSurface(
              session: session,
              labels: labels,
              outputDirectory: outputDirectory,
              onCaptured: onCaptured,
              onClose: () => Navigator.of(context).pop(),
              kinds: kinds,
              cache: cache,
              expandFrom: from,
              expansion: from == null ? null : progress,
              controlsReveal: from == null ? null : progress,
              mirrorFrontPhotos: mirrorFrontPhotos,
              onVideoRefused: onVideoRefused,
              videoNeedsMicrophone: videoNeedsMicrophone,
              policy: policy,
              resultBuilder: resultBuilder,
              onShotRemoved: onShotRemoved,
              shots: shots,
              onShotsTap: onShotsTap,
              shotOrder: shotOrder,
              onShotToggle: onShotToggle,
              shotSelection: shotSelection,
            );
          },
          transitionsBuilder: (context, animation, _, child) {
            if (from != null) return child;
            return FadeTransition(
              opacity: CurvedAnimation(
                parent: animation,
                curve: Curves.easeOutCubic,
                reverseCurve: Curves.easeInCubic,
              ),
              child: child,
            );
          },
        ),
      );
    } finally {
      _shown.remove(session);
    }
  }

  static final Set<CameraSession> _shown = {};

  /// How long the shutter is held before a video starts recording under
  /// `CaptureSurfacePolicy.$Android`.
  static const Duration holdToRecord = Duration(milliseconds: 800);

  /// The running session.
  final CameraSession session;

  /// Words for screen readers.
  final CaptureSurfaceLabels labels;

  /// Where captures are written.
  final String outputDirectory;

  /// Called with every shot.
  final ValueChanged<CameraShot> onCaptured;

  /// Called by the close button.
  final VoidCallback onClose;

  /// What the shutter takes.
  final CaptureKinds kinds;

  /// Where captures move to, under a local key; null to leave them as files.
  final CaptureCache? cache;

  /// The rectangle (global) the preview expands from as [expansion] runs;
  /// null for a surface that is simply there.
  final Rect? expandFrom;

  /// The preview's expansion, 0 at [expandFrom] and 1 at the whole screen.
  /// Only the preview moves: the controls are laid out at the whole screen
  /// throughout. Null without [expandFrom].
  final Animation<double>? expansion;

  /// The controls' opacity, which [show] runs with the [expansion] (and,
  /// backwards, before it); they take no touches until it is 1. Null for
  /// controls that are simply there.
  final Animation<double>? controlsReveal;

  /// Whether a front camera's photos are saved mirrored, as the preview
  /// shows them (a chat's camera does); videos never are.
  final bool mirrorFrontPhotos;

  /// Called when the shutter would record a video but may not: a hold on a
  /// surface for photos only, or a microphone refused. The host shows its
  /// notice; nothing is recorded.
  final ValueChanged<CaptureVideoRefusal>? onVideoRefused;

  /// Whether a video needs the microphone. Without access, a hold asks for
  /// it (the platform's prompt) and records nothing: the next hold records
  /// once it is granted, and a refusal goes to [onVideoRefused].
  final bool videoNeedsMicrophone;

  /// The platform's behaviour: shutter timing and modes, zoom, focus, the
  /// timer and what a recording hides.
  final CaptureSurfacePolicy policy;

  /// What a shot shows as in the results strip ([CaptureSurfacePolicy.
  /// resultsStrip]); null for a plain tile.
  final Widget Function(BuildContext context, CameraShot shot)? resultBuilder;

  /// Called when a shot is removed from the results strip: the host drops
  /// it from its selection.
  final ValueChanged<CameraShot>? onShotRemoved;

  /// The shots the host keeps, oldest first, which the strip and the counter
  /// show; null for the surface's own list of the shots it took.
  final ValueListenable<List<CameraShot>>? shots;

  /// Called by the shots counter: the host opens its viewer over them.
  final VoidCallback? onShotsTap;

  /// A kept shot's number in the host's selection (1-based), or null when
  /// it is not selected: the strip cell's check shows it.
  final int? Function(CameraShot shot)? shotOrder;

  /// Called by a strip cell's tap or check: the host toggles the shot in its
  /// selection.
  final ValueChanged<CameraShot>? onShotToggle;

  /// Tells the strip that [shotOrder]'s answers changed (the host's
  /// selection).
  final Listenable? shotSelection;

  @override
  State<CameraCaptureSurface> createState() => _CameraCaptureSurfaceState();
}

class _CameraCaptureSurfaceState extends State<CameraCaptureSurface>
    with TickerProviderStateMixin {
  int? _foundCap;

  // --- Focus, zoom and the recording timer ---

  // The ring at the last tap: it closes in over 200 ms (outer radius from
  // twice its 30 px to 30, the inner disc from 0 to 30), then the disc and
  // the ring fade over 150 ms each, decelerating.
  static const double _ringRadius = 30;
  late final AnimationController _ring;
  Offset? _ringAt;

  // Two fingers: once their distance has moved by [_pinchSlop], the zoom
  // follows each further change, by its length over 100 px.
  static const double _pinchSlop = 25;
  final Map<int, Offset> _pointers = {};
  double? _pinchFrom;
  bool _pinching = false;

  // --- The zoom slider ---

  // It fades in over 180 ms when the zoom is used (a pinch, the slider, a
  // drag up from the held shutter) and out 2 s after the last use.
  late final AnimationController _zoomFade;
  Timer? _zoomHide;
  // A step of the slider's minus or plus, over 180 ms.
  late final AnimationController _zoomStep;
  double _stepFrom = 0;
  double _stepTo = 0;
  // Whether the held shutter's drag zoomed.
  bool _dragZoomed = false;

  void _showZoom() {
    if (_policy.zoomControl != CaptureZoomControl.slider) return;
    _zoomFade.forward().ignore();
    _zoomHide?.cancel();
    _zoomHide = Timer(const Duration(seconds: 2), () {
      if (mounted) _zoomFade.reverse().ignore();
    });
  }

  void _zoomTo(double zoom, {bool stopStep = true}) {
    if (stopStep) _zoomStep.stop();
    final clamped = zoom.clamp(0.0, 1.0);
    unawaited(_quietly(() => _session.setZoom(clamped)));
    _showZoom();
  }

  // To the quarter below or above, as the slider's minus and plus do.
  void _stepZoom(int direction) {
    final to = (_value.zoom / 0.25).floor() * 0.25 + 0.25 * direction;
    if (to < 0 || to > 1) return;
    _stepFrom = _value.zoom;
    _stepTo = to;
    _zoomStep.forward(from: 0).ignore();
    _showZoom();
  }

  void _onStep() {
    final t = Curves.easeInOut.transform(_zoomStep.value);
    _zoomTo(_stepFrom + (_stepTo - _stepFrom) * t, stopStep: false);
  }

  // The held shutter's finger above its top zooms by the distance over 200;
  // back down, the zoom returns to the widest. On the factor scale, while
  // the hold records: 1 + the distance up from the press over 60.
  void _holdMove(Offset local, Offset fromPress) {
    if (_policy.zoomScale == CaptureZoomScale.factor) {
      if (!_value.isRecording) return;
      _zoomFactorTo(fromPress.dy < 0 ? 1 + -fromPress.dy / 60 : 1);
      return;
    }
    if (local.dy < 0) {
      _dragZoomed = true;
      _zoomTo(-local.dy / 200);
    } else if (_dragZoomed) {
      _dragZoomed = false;
      _zoomTo(0);
    }
  }

  CaptureSurfacePolicy get _policy => widget.policy;

  // --- Modes ---

  // The mode control shows when the policy has one, both kinds are allowed
  // and the labels name the modes.
  bool get _hasModes =>
      _policy.modeControl &&
      widget.kinds == CaptureKinds.photoAndVideo &&
      widget.labels.videoMode != null &&
      widget.labels.photoMode != null;
  late bool _videoMode = widget.kinds == CaptureKinds.video;

  void _setVideoMode(bool video) {
    if (_value.isRecording || video == _videoMode) return;
    setState(() => _videoMode = video);
  }

  // --- Factor zoom ---

  double get _maxFactor =>
      math.min(_value.maxZoomFactor, _policy.maxZoomFactor);

  void _zoomFactorTo(double factor, {bool stopLens = true}) {
    if (stopLens) _lens.stop();
    final f = factor.clamp(_value.minZoomFactor, _maxFactor);
    unawaited(_quietly(() => _session.setZoomFactor(f)));
  }

  // A lens tap moves the zoom there over 300 ms.
  late final AnimationController _lens;
  double _lensFrom = 1;
  double _lensTo = 1;

  void _goToLens(double lens) {
    _lensFrom = _value.zoomFactor;
    _lensTo = lens;
    _lens.forward(from: 0).ignore();
  }

  void _onLens() {
    final t = Curves.easeOut.transform(_lens.value);
    _zoomFactorTo(_lensFrom + (_lensTo - _lensFrom) * t, stopLens: false);
  }

  Timer? _zoomBack;

  // --- The focus crosshair and exposure ---

  Offset? _crossAt;
  late final AnimationController _crossIn;
  late final AnimationController _crossDim;
  Timer? _crossIdle;
  bool _exposing = false;

  void _crosshair(Offset at) {
    _crossIdle?.cancel();
    setState(() {
      _crossAt = at;
      _exposing = false;
    });
    _crossIn.forward(from: 0).ignore();
    _crossDim.value = 0;
    if (_value.hasExposure && _value.exposure != 0) {
      unawaited(_quietly(() => _session.setExposure(0)));
    }
    // It dims to half 0.9 s after its 1 s of attention, over 0.2 s.
    _crossIdle = Timer(const Duration(milliseconds: 1900), () {
      if (mounted) _crossDim.forward().ignore();
    });
  }

  // A vertical drag after a focus tap sets the exposure: down darker, up
  // brighter, the whole range over 750 px each way.
  void _expose(DragUpdateDetails details) {
    if (_crossAt == null || !_value.hasExposure) return;
    _crossIdle?.cancel();
    _crossDim.value = 0;
    final next = (_value.exposure - details.delta.dy / 750).clamp(-1.0, 1.0);
    if (!_exposing) setState(() => _exposing = true);
    unawaited(_quietly(() => _session.setExposure(next)));
  }

  void _exposed(DragEndDetails _) {
    _crossIdle?.cancel();
    _crossIdle = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      setState(() => _exposing = false);
      _crossDim.forward().ignore();
    });
  }

  // --- Swipe to dismiss ---

  // One finger moved 25 px (0.4 cm) up or down starts the drag: the preview
  // follows the finger and the controls fade over 220 ms. Released past a
  // sixth of the height, the page closes from where the preview is;
  // otherwise preview and controls come back over 250 ms, decelerating.
  static const double _dismissSlop = 25;
  final ValueNotifier<double> _dragY = ValueNotifier(0);
  late final AnimationController _panel;
  late final AnimationController _settle;
  double _settleFrom = 0;
  double _dragTotal = 0;
  bool _dismissing = false;
  bool _exposureDrag = false;

  void _dragStart(DragStartDetails _) {
    _dragTotal = 0;
    _dismissing = false;
    _exposureDrag =
        _policy.focus == CaptureFocusMark.crosshair &&
        _crossAt != null &&
        _value.hasExposure;
  }

  void _dragUpdate(DragUpdateDetails details) {
    if (_exposureDrag) return _expose(details);
    if (_pointers.length > 1) return;
    _dragTotal += details.delta.dy;
    if (!_dismissing) {
      if (_dragTotal.abs() < _dismissSlop) return;
      _dismissing = true;
      _settle.stop();
      _panel
        ..duration = const Duration(milliseconds: 220)
        ..animateTo(0, curve: const Cubic(0.25, 0.1, 0.25, 1)).ignore();
      return;
    }
    _dragY.value += details.delta.dy;
  }

  void _dragEnd(DragEndDetails details, double height) {
    if (_exposureDrag) return _exposed(details);
    if (!_dismissing) return;
    _dismissing = false;
    if (_dragY.value.abs() > height / 6 && !_busy) {
      widget.onClose();
      return;
    }
    _settleFrom = _dragY.value;
    _settle.forward(from: 0).ignore();
    _panel
      ..duration = const Duration(milliseconds: 250)
      ..animateTo(1, curve: const _Decelerate(1.5)).ignore();
  }

  void _onSettle() {
    _dragY.value =
        _settleFrom * (1 - const _Decelerate(1.5).transform(_settle.value));
  }

  // --- The photo blink and the results ---

  late final AnimationController _blink;
  final List<CameraShot> _results = [];

  // A small picture of each shot taken here, read from its file (a photo)
  // or its poster (a recording) before the file moves into a cache.
  final Map<Object, ui.Image> _thumbs = {};

  static Object _thumbKey(CameraShot shot) => shot.key ?? shot.output.path;

  // The file's bytes are read before the capture moves into a cache; the
  // decode then runs on its own and the cell shows the picture when it is
  // ready, so the next shot never waits for it.
  Future<void> _thumbnail(
    CaptureOutput output, {
    required bool isVideo,
    required Object key,
  }) async {
    // Only the strip's own cells draw them.
    final drawn =
        widget.resultBuilder == null &&
        _policy.shotsCounter &&
        widget.labels.shotsCount != null;
    final path = isVideo ? output.posterPath : output.path;
    if (!drawn || path == null) return;
    final Uint8List bytes;
    try {
      bytes = await File(path).readAsBytes();
    } on Object {
      return;
    }
    unawaited(() async {
      try {
        final codec = await ui.instantiateImageCodec(bytes, targetWidth: 240);
        final frame = await codec.getNextFrame();
        codec.dispose();
        if (!mounted) return frame.image.dispose();
        setState(() {
          _thumbs[key]?.dispose();
          _thumbs[key] = frame.image;
        });
      } on Object {
        // No picture: the cell keeps its background.
      }
    }());
  }

  // The host's shots when it keeps them, else the ones taken here.
  List<CameraShot> get _shotList => widget.shots?.value ?? _results;

  bool get _showsCounter =>
      _policy.shotsCounter &&
      widget.labels.shotsCount != null &&
      _shotList.isNotEmpty;

  void _onShots() {
    if (mounted) setState(() {});
  }

  void _removeResult(CameraShot shot) {
    if (widget.shots == null) setState(() => _results.remove(shot));
    widget.onShotRemoved?.call(shot);
  }

  // The recording's seconds.
  Timer? _tick;
  int _seconds = 0;
  bool _wasRecording = false;

  void _focus(TapUpDetails details, Size size) {
    if (size.isEmpty) return;
    final at = details.localPosition;
    final point = Offset(
      (at.dx / size.width).clamp(0.0, 1.0),
      (at.dy / size.height).clamp(0.0, 1.0),
    );
    unawaited(_quietly(() => _session.focusAt(point)));
    if (_policy.focus == CaptureFocusMark.crosshair) return _crosshair(at);
    setState(() => _ringAt = at);
    _ring.forward(from: 0).ignore();
  }

  void _pointerDown(PointerDownEvent event) {
    _pointers[event.pointer] = event.localPosition;
    _pinching = false;
    _pinchFrom = _pointers.length == 2
        ? (_pointers.values.first - _pointers.values.last).distance
        : null;
  }

  void _pointerMove(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) return;
    _pointers[event.pointer] = event.localPosition;
    if (_pointers.length != 2) return;
    final [a, b] = _pointers.values.toList();
    final distance = (a - b).distance;
    final from = _pinchFrom;
    if (_policy.zoomScale == CaptureZoomScale.factor) {
      // Each move scales by its share of the last distance.
      _pinchFrom = distance;
      if (from == null || from == 0) return;
      var delta = (distance / from - 1) * 1.25;
      if (_value.zoomFactor > 2) delta *= 2;
      _zoomFactorTo(_value.zoomFactor + delta);
      return;
    }
    if (from == null) {
      _pinchFrom = distance;
      return;
    }
    if (!_pinching) {
      if ((distance - from).abs() < _pinchSlop) return;
      _pinching = true;
      _pinchFrom = distance;
      return;
    }
    _pinchFrom = distance;
    _zoomTo(_value.zoom + (distance - from) / 100);
  }

  void _pointerUp(PointerEvent event) {
    _pointers.remove(event.pointer);
    if (_pointers.length < 2) {
      _pinchFrom = null;
      _pinching = false;
    }
  }

  void _onValue() {
    final recording = _value.isRecording;
    if (recording == _wasRecording) return;
    _wasRecording = recording;
    _tick?.cancel();
    if (!recording) {
      if (_policy.zoomResetAfterRecording case final after?) {
        _zoomBack?.cancel();
        _zoomBack = Timer(after, () {
          if (mounted) _zoomFactorTo(1);
        });
      }
    }
    if (recording) {
      _seconds = 0;
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _seconds++);
      });
    }
    if (mounted) setState(() {});
  }

  static String _clock(Duration time) {
    final seconds = time.inSeconds;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  Widget _hands(BuildContext context, Widget controls) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
      final ringAt = _ringAt;
      return Stack(
        fit: StackFit.expand,
        children: [
          Listener(
            onPointerDown: _pointerDown,
            onPointerMove: _pointerMove,
            onPointerUp: _pointerUp,
            onPointerCancel: _pointerUp,
            behavior: HitTestBehavior.translucent,
            child: GestureDetector(
              key: const ValueKey('mpx-capture-picture'),
              behavior: HitTestBehavior.opaque,
              onTapUp: (details) => _focus(details, size),
              onVerticalDragStart: _dragStart,
              onVerticalDragUpdate: _dragUpdate,
              onVerticalDragEnd: (details) => _dragEnd(details, size.height),
            ),
          ),
          if (_crossAt case final at?)
            Positioned(
              left: at.dx - 100,
              top: at.dy - 100,
              width: 200,
              height: 200,
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: Listenable.merge([
                    _crossIn,
                    _crossDim,
                    _session.value,
                  ]),
                  builder: (context, _) => CustomPaint(
                    key: const ValueKey('mpx-capture-crosshair'),
                    painter: CaptureCrosshairPainter(
                      appear: _crossIn.value,
                      opacity: 1 - 0.5 * _crossDim.value,
                      exposure: _value.hasExposure ? _value.exposure : null,
                      track: _exposing,
                    ),
                  ),
                ),
              ),
            ),
          IgnorePointer(
            child: FadeTransition(
              opacity: _blink,
              child: const ColoredBox(
                key: ValueKey('mpx-capture-blink'),
                color: Color(0xFF000000),
              ),
            ),
          ),
          if (_policy.zoomControl == CaptureZoomControl.lenses)
            Positioned(
              left: 0,
              right: 0,
              bottom: MediaQuery.paddingOf(context).bottom + 140 + 18,
              height: 43,
              child: ValueListenableBuilder<CameraSessionValue>(
                valueListenable: _session.value,
                builder: (context, value, _) => value.lenses.length < 2
                    ? const SizedBox.shrink()
                    : Center(
                        child: CaptureLensPill(
                          key: const ValueKey('mpx-capture-lenses'),
                          lenses: [
                            for (final lens in value.lenses)
                              if (lens <= _maxFactor) lens,
                          ],
                          factor: value.zoomFactor,
                          minFactor: value.minZoomFactor,
                          maxFactor: _maxFactor,
                          onLens: _goToLens,
                          onFactor: _zoomFactorTo,
                        ),
                      ),
              ),
            ),
          if (_showsCounter) ...[
            Positioned(
              left: 0,
              right: 0,
              bottom: MediaQuery.paddingOf(context).bottom + 8,
              height: 80,
              child: ListView(
                key: const ValueKey('mpx-capture-shots'),
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                children: [
                  for (final (i, shot) in _shotList.indexed)
                    // 80 square cells 6 apart, the last with no gap.
                    Padding(
                      key: ValueKey((
                        'mpx-capture-shot',
                        shot.key ?? shot.output.path,
                      )),
                      padding: EdgeInsetsDirectional.only(
                        end: i == _shotList.length - 1 ? 0 : 6,
                      ),
                      child: SizedBox.square(
                        dimension: 80,
                        child:
                            widget.resultBuilder?.call(context, shot) ??
                            ListenableBuilder(
                              listenable:
                                  widget.shotSelection ?? const _Never(),
                              builder: (context, _) => _ShotCell(
                                shot: shot,
                                thumbnail: _thumbs[_thumbKey(shot)],
                                order: widget.shotOrder?.call(shot),
                                onToggle: () => widget.onShotToggle?.call(shot),
                              ),
                            ),
                      ),
                    ),
                ],
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: MediaQuery.paddingOf(context).bottom + 129 + 96,
              height: 38,
              child: Center(
                child: _ShotsCounter(
                  key: const ValueKey('mpx-capture-counter'),
                  text: widget.labels.shotsCount!(
                    _shotList.where((s) => !s.isVideo).length,
                    _shotList.where((s) => s.isVideo).length,
                  ),
                  onTap: () {
                    if (!_busy && !_value.isRecording)
                      widget.onShotsTap?.call();
                  },
                ),
              ),
            ),
          ],
          if (_policy.resultsStrip && _shotList.isNotEmpty)
            Positioned(
              left: 0,
              right: 0,
              bottom: MediaQuery.paddingOf(context).bottom + 140 + 18 + 43 + 12,
              height: 56,
              child: _ResultsStrip(
                key: const ValueKey('mpx-capture-results'),
                shots: _shotList,
                builder: widget.resultBuilder,
                onRemove: _removeResult,
              ),
            ),
          if (ringAt != null)
            Positioned(
              left: ringAt.dx - 2 * _ringRadius,
              top: ringAt.dy - 2 * _ringRadius,
              width: 4 * _ringRadius,
              height: 4 * _ringRadius,
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _ring,
                  builder: (context, _) => CustomPaint(
                    key: const ValueKey('mpx-capture-focus'),
                    painter: _FocusRing(_ring.value),
                  ),
                ),
              ),
            ),
          if (_policy.zoomControl == CaptureZoomControl.slider)
            Positioned(
              left: 0,
              right: 0,
              bottom:
                  MediaQuery.paddingOf(context).bottom +
                  126 +
                  (_showsCounter ? 96 + 38 : 0),
              height: 50,
              child: AnimatedBuilder(
                animation: _zoomFade,
                builder: (context, child) => IgnorePointer(
                  ignoring: _zoomFade.value == 0,
                  child: Opacity(opacity: _zoomFade.value, child: child),
                ),
                child: ValueListenableBuilder<CameraSessionValue>(
                  valueListenable: _session.value,
                  builder: (context, value, _) => _ZoomSlider(
                    key: const ValueKey('mpx-capture-zoom'),
                    zoom: value.zoom,
                    onZoom: _zoomTo,
                    onStep: _stepZoom,
                  ),
                ),
              ),
            ),
          controls,
          if (_value.isRecording && _policy.timer == CaptureTimerStyle.redBox)
            Positioned(
              top: MediaQuery.paddingOf(context).top + 12,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: Center(
                  child: CaptureRedTimer(
                    key: const ValueKey('mpx-capture-timer'),
                    seconds: _seconds,
                  ),
                ),
              ),
            )
          else if (_value.isRecording)
            Positioned(
              top: MediaQuery.paddingOf(context).top + 16,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: Center(
                  child: Container(
                    key: const ValueKey('mpx-capture-timer'),
                    padding: const EdgeInsets.fromLTRB(24, 5, 10, 5),
                    decoration: BoxDecoration(
                      color: const Color(0x66000000),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Stack(
                      clipBehavior: Clip.none,
                      alignment: Alignment.centerLeft,
                      children: [
                        // The red dot of a recording, in the pill's
                        // leading padding.
                        const Positioned(
                          left: -15,
                          child: SizedBox.square(
                            dimension: 8,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Color(0xFFFF3B30),
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        ),
                        Text(
                          _clock(Duration(seconds: _seconds)),
                          style: const TextStyle(
                            color: Color(0xFFFFFFFF),
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
  bool _busy = false;
  int _shots = 0;

  CameraSession get _session => widget.session;
  CameraSessionValue get _value => _session.value.value;

  @override
  void initState() {
    super.initState();
    _ring =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 500),
        )..addStatusListener((status) {
          if (status.isCompleted && mounted) setState(() => _ringAt = null);
        });
    _zoomFade = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    _zoomStep = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    )..addListener(_onStep);
    _lens = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    )..addListener(_onLens);
    _crossIn = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
    _crossDim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _blink =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 70),
          reverseDuration: const Duration(milliseconds: 150),
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed) _blink.reverse().ignore();
        });
    _panel = AnimationController(vsync: this, value: 1);
    _settle = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    )..addListener(_onSettle);
    widget.shots?.addListener(_onShots);
    _session.value.addListener(_onValue);
    _wasRecording = _value.isRecording;
    _foundCap = _value.frameRateCap;
    // After the build that mounts the surface: the slot's preview listens to
    // the same session and must not be marked dirty mid-build.
    if (_value.state != CameraSessionState.closed && _foundCap != null) {
      scheduleMicrotask(
        () => unawaited(_quietly(() => _session.setFrameRateCap(null))),
      );
    }
  }

  @override
  void didUpdateWidget(CameraCaptureSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.shots, widget.shots)) {
      oldWidget.shots?.removeListener(_onShots);
      widget.shots?.addListener(_onShots);
    }
  }

  @override
  void dispose() {
    widget.shots?.removeListener(_onShots);
    _session.value.removeListener(_onValue);
    _tick?.cancel();
    _ring.dispose();
    _zoomHide?.cancel();
    _zoomFade.dispose();
    _zoomStep.dispose();
    _lens.dispose();
    _crossIn.dispose();
    _crossDim.dispose();
    _crossIdle?.cancel();
    _zoomBack?.cancel();
    _blink.dispose();
    for (final image in _thumbs.values) {
      image.dispose();
    }
    _panel.dispose();
    _settle.dispose();
    _dragY.dispose();
    final session = _session;
    final found = _foundCap;
    // Out of the locked tree: other widgets listen to the same session.
    scheduleMicrotask(() {
      final value = session.value.value;
      if (value.state == CameraSessionState.closed) return;
      if (value.isRecording) unawaited(_quietly(session.stopRecording));
      if (value.frameRateCap != found) {
        unawaited(_quietly(() => session.setFrameRateCap(found)));
      }
    });
    super.dispose();
  }

  // A control on a session that closed meanwhile is nothing to report.
  static Future<void> _quietly(Future<Object?> Function() call) async {
    try {
      await call();
    } on CaptureException {
      // The session closed or is not available; the surface shows its state.
    }
  }

  String _output(String extension) =>
      '${widget.outputDirectory}/camera-'
      '${DateTime.now().microsecondsSinceEpoch}-${_shots++}.$extension';

  Future<void> _deliver(CaptureOutput output, {required bool isVideo}) async {
    // Each shot starts the next from the widest view.
    if (_policy.zoomResetsAfterEveryShot && _value.zoom != 0) {
      unawaited(_quietly(() => _session.setZoom(0)));
    }
    final cache = widget.cache;
    final key = cache?.mintKey();
    await _thumbnail(output, isVideo: isVideo, key: key ?? output.path);
    if (cache != null && key != null) await cache.put(key, output);
    final shot = CameraShot(isVideo: isVideo, output: output, key: key);
    if (widget.shots == null && mounted) setState(() => _results.add(shot));
    widget.onCaptured(shot);
  }

  Future<void> _photo() async {
    if (_busy || !_value.isAvailable) return;
    _busy = true;
    if (_policy.photoBlink) {
      // 50 ms after the release the preview darkens for 70 ms and comes
      // back over 150 ms.
      Timer(const Duration(milliseconds: 50), () {
        if (mounted) {
          _blink.forward(from: 0).ignore();
        }
      });
    }
    try {
      final output = await _session.capturePhoto(
        outputPath: _output('jpg'),
        mirrorFront: widget.mirrorFrontPhotos,
      );
      await _deliver(output, isVideo: false);
    } on CaptureException {
      // The session's state tells; nothing was taken.
    } finally {
      _busy = false;
    }
  }

  // Whether a recording may start now: with the microphone, when videos
  // need it, asked for first (that press records nothing).
  Future<bool> _mayRecord() async {
    if (!widget.videoNeedsMicrophone) return true;
    if (_value.microphone == MicrophoneAccess.granted) return true;
    try {
      final access = await _session.requestMicrophone();
      if (access != MicrophoneAccess.granted && mounted) {
        widget.onVideoRefused?.call(CaptureVideoRefusal.microphone);
      }
    } on CaptureException {
      // The session closed meanwhile.
    }
    return false;
  }

  Future<void> _startVideo() async {
    if (_busy || !_value.isAvailable || _value.isRecording) return;
    if (!await _mayRecord()) return;
    if (!mounted || _busy || !_value.isAvailable || _value.isRecording) return;
    await _quietly(() => _session.startRecording(outputPath: _output('mp4')));
  }

  Future<void> _stopVideo() async {
    if (!_value.isRecording) return;
    _busy = true;
    try {
      final output = await _session.stopRecording();
      await _deliver(output, isVideo: true);
    } on CaptureException {
      // The recording broke; its state tells.
    } finally {
      _busy = false;
    }
  }

  void _tap() {
    final kinds = widget.kinds;
    if (_value.isRecording) {
      unawaited(_stopVideo());
    } else if (_hasModes) {
      unawaited(_videoMode ? _startVideo() : _photo());
    } else if (kinds.photos) {
      unawaited(_photo());
    } else {
      unawaited(_startVideo());
    }
  }

  // With a mode control a hold in photo mode moves to video mode and
  // records until the release.
  void _holdStart() {
    if (_hasModes && !_videoMode) setState(() => _videoMode = true);
    if (widget.kinds.videos) return unawaited(_startVideo());
    widget.onVideoRefused?.call(CaptureVideoRefusal.notAllowed);
  }

  void _holdEnd() {
    if (widget.kinds.videos) unawaited(_stopVideo());
  }

  // The camera switch: ignored while a photo is taken, and (in the session)
  // while a switch runs.
  void _switchCamera() {
    if (_busy) return;
    unawaited(_quietly(_session.switchCamera));
  }

  // The close button: ignored while a photo is taken.
  void _close() {
    if (_busy) return;
    widget.onClose();
  }

  // The flash icon's change runs 220 ms; a tap meanwhile is ignored.
  static const Duration _flashSwap = Duration(milliseconds: 220);
  bool _flashSwapping = false;

  // The policy's flash modes in turn.
  void _cycleFlash() {
    if (_flashSwapping) return;
    _flashSwapping = true;
    Timer(_flashSwap, () => _flashSwapping = false);
    final modes = _policy.flashModes;
    final at = modes.indexOf(_value.flash);
    final next = modes[(at + 1) % modes.length];
    unawaited(_quietly(() => _session.setFlash(next)));
  }

  // A control that a recording hides as the policy says.
  Widget _whileRecording(
    Key key,
    bool recording,
    Widget child, {
    bool slides = true,
  }) => switch (_policy.recordingChrome) {
    CaptureRecordingChrome.slideAside when slides => _AsideWhileRecording(
      key: key,
      recording: recording,
      child: child,
    ),
    CaptureRecordingChrome.slideAside => KeyedSubtree(key: key, child: child),
    CaptureRecordingChrome.fade => _FadeWhileRecording(
      key: key,
      recording: recording,
      child: child,
    ),
  };

  @override
  Widget build(BuildContext context) {
    final preview = ColoredBox(
      color: const Color(0xFF000000),
      child: CameraPreview(session: _session),
    );
    final controls = _hands(
      context,
      ValueListenableBuilder<CameraSessionValue>(
        valueListenable: _session.value,
        builder: (context, value, _) => _controls(value),
      ),
    );
    final from = widget.expandFrom;
    final expand = widget.expansion;
    final fade = widget.controlsReveal;
    final revealed = switch (fade) {
      // Laid out at the whole screen at every step; shown, and touchable,
      // only once the preview fills it.
      final fade? => AnimatedBuilder(
        animation: fade,
        child: controls,
        builder: (context, controls) => IgnorePointer(
          ignoring: fade.value < 1 && fade.status != AnimationStatus.completed,
          child: Opacity(
            key: const ValueKey('mpx-capture-controls-fade'),
            opacity: fade.value.clamp(0.0, 1.0),
            child: controls,
          ),
        ),
      ),
      null => controls,
    };
    // A dismiss drag fades the controls.
    final shown = AnimatedBuilder(
      animation: _panel,
      child: revealed,
      builder: (context, child) => Opacity(
        key: const ValueKey('mpx-capture-panel'),
        opacity: _panel.value,
        child: child,
      ),
    );
    if (from == null || expand == null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          ValueListenableBuilder<double>(
            valueListenable: _dragY,
            child: preview,
            builder: (context, dy, preview) => Transform.translate(
              key: const ValueKey('mpx-capture-drag'),
              offset: Offset(0, dy),
              child: preview,
            ),
          ),
          shown,
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // The route covers the screen: [from], global, is in its space.
        final screen = Offset.zero & constraints.biggest;
        return Stack(
          fit: StackFit.expand,
          children: [
            AnimatedBuilder(
              // The close runs from where a dismiss drag left the preview.
              animation: Listenable.merge([expand, _dragY]),
              child: preview,
              builder: (context, preview) => Stack(
                children: [
                  Positioned.fromRect(
                    key: const ValueKey('mpx-capture-drag'),
                    rect: Rect.lerp(
                      from,
                      screen.shift(Offset(0, _dragY.value)),
                      expand.value,
                    )!,
                    child: ClipRect(child: preview),
                  ),
                ],
              ),
            ),
            shown,
          ],
        );
      },
    );
  }

  Widget _controls(CameraSessionValue value) => IgnorePointer(
    ignoring: _policy.locksWhileSwitching && value.isSwitching,
    child: _controlsOf(value),
  );

  Widget _controlsOf(CameraSessionValue value) {
    final labels = widget.labels;
    return SafeArea(
      key: const ValueKey('mpx-capture-controls'),
      child: Padding(
        // The shots strip takes the bottom 96.
        padding: const EdgeInsets.all(
          8,
        ).copyWith(bottom: 8 + (_showsCounter ? 96 : 0)),
        child: Column(
          children: [
            Row(
              children: [
                _whileRecording(
                  const ValueKey('mpx-capture-close-slot'),
                  value.isRecording,
                  slides: false,
                  _GlyphButton(
                    key: const ValueKey('mpx-capture-close'),
                    glyph: _Glyph.close,
                    label: labels.close,
                    onTap: _close,
                  ),
                ),
                const Spacer(),
                if (value.hasFlash)
                  _whileRecording(
                    const ValueKey('mpx-capture-flash-slot'),
                    value.isRecording,
                    _GlyphButton(
                      key: const ValueKey('mpx-capture-flash'),
                      glyph: switch (value.flash) {
                        CameraFlash.off => _Glyph.flashOff,
                        CameraFlash.auto => _Glyph.flashAuto,
                        CameraFlash.on => _Glyph.flashOn,
                      },
                      swap: _flashSwap,
                      label: labels.flash,
                      value: value.flash.name,
                      onTap: _cycleFlash,
                    ),
                  ),
              ],
            ),
            const Spacer(),
            if (_hasModes)
              _whileRecording(
                const ValueKey('mpx-capture-modes-slot'),
                value.isRecording,
                slides: false,
                CaptureModeControl(
                  key: const ValueKey('mpx-capture-modes'),
                  video: labels.videoMode!,
                  photo: labels.photoMode!,
                  videoMode: _videoMode,
                  onVideoMode: _setVideoMode,
                ),
              ),
            Row(
              children: [
                const SizedBox(width: 48),
                const Spacer(),
                _Shutter(
                  label: labels.shutter,
                  style: _policy.shutter,
                  holdToRecord: _policy.holdToRecord,
                  videoMode: _hasModes ? _videoMode : !widget.kinds.photos,
                  recording: value.isRecording,
                  enabled: value.isAvailable && !value.isPaused,
                  onTap: _tap,
                  onHoldStart: _holdStart,
                  onHoldMove: _holdMove,
                  onHoldEnd: _holdEnd,
                ),
                const Spacer(),
                if (value.canSwitchCamera)
                  _whileRecording(
                    const ValueKey('mpx-capture-switch-slot'),
                    value.isRecording,
                    _GlyphButton(
                      key: const ValueKey('mpx-capture-switch'),
                      glyph: _Glyph.switchCamera,
                      label: labels.switchCamera,
                      onTap: _switchCamera,
                    ),
                  )
                else
                  const SizedBox(width: 48),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// While a recording runs, a control slides 30 px out towards its edge and
// fades, over 150 ms on an ease curve, and takes no touches; it comes back
// the same way.
class _AsideWhileRecording extends StatelessWidget {
  const _AsideWhileRecording({
    required this.recording,
    required this.child,
    super.key,
  });

  final bool recording;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final outward = Directionality.of(context) == TextDirection.ltr ? 1 : -1;
    return IgnorePointer(
      ignoring: recording,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: recording ? 1 : 0),
        duration: const Duration(milliseconds: 150),
        curve: Curves.ease,
        builder: (context, t, child) => Transform.translate(
          offset: Offset(outward * 30 * t, 0),
          child: Opacity(opacity: 1 - t, child: child),
        ),
        child: child,
      ),
    );
  }
}

// A listenable that never notifies.
class _Never implements Listenable {
  const _Never();

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

// A kept shot in the strip, as the reference draws its attach cell there:
// the picture 80 square over a 5 % black background; a recording's
// duration in a 17 high pill at its bottom start (4 in, 5 padding, a
// play mark 8 x 10, the time 12 bold white, 13 after the mark's start, on
// 40 % black, radius 4); the check 24 at 52, 4 (a white ring, or the
// selection number on the accent when checked). A tap anywhere toggles.
class _ShotCell extends StatelessWidget {
  const _ShotCell({
    required this.shot,
    required this.thumbnail,
    required this.order,
    required this.onToggle,
  });

  final CameraShot shot;
  final ui.Image? thumbnail;
  final int? order;
  final VoidCallback onToggle;

  static String _duration(Duration time) {
    final s = time.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final picture = thumbnail;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onToggle,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Color(0x0C000000)),
          if (picture != null) RawImage(image: picture, fit: BoxFit.cover),
          if (shot.isVideo)
            PositionedDirectional(
              start: 4,
              bottom: 4,
              height: 17,
              child: Container(
                key: const ValueKey('mpx-capture-shot-duration'),
                padding: const EdgeInsets.symmetric(horizontal: 5),
                decoration: BoxDecoration(
                  color: const Color(0x66000000),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CustomPaint(
                      size: Size(8, 10),
                      painter: _PlayMarkPainter(),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      _duration(shot.output.duration),
                      style: const TextStyle(
                        color: Color(0xFFFFFFFF),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Positioned(
            left: 52 + 1,
            top: 4 + 1,
            width: 24,
            height: 24,
            child: CustomPaint(
              key: const ValueKey('mpx-capture-shot-check'),
              painter: _CheckPainter(order),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayMarkPainter extends CustomPainter {
  const _PlayMarkPainter();

  @override
  void paint(Canvas canvas, Size size) => canvas.drawPath(
    Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, size.height / 2)
      ..lineTo(0, size.height)
      ..close(),
    Paint()..color = const Color(0xFFFFFFFF),
  );

  @override
  bool shouldRepaint(_PlayMarkPainter oldDelegate) => false;
}

// The selection check: unchecked a white ring 1.5 thick over a light
// shade; checked the accent disc with a white ring and the number.
class _CheckPainter extends CustomPainter {
  const _CheckPainter(this.order);

  final int? order;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final number = order;
    if (number == null) {
      canvas
        ..drawCircle(c, r - 1, Paint()..color = const Color(0x22000000))
        ..drawCircle(
          c,
          r - 1,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = const Color(0xFFFFFFFF),
        );
      return;
    }
    canvas
      ..drawCircle(c, r, Paint()..color = const Color(0xFF229AF0))
      ..drawCircle(
        c,
        r - 0.75,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = const Color(0xFFFFFFFF),
      );
    final text = TextPainter(
      text: TextSpan(
        text: '$number',
        style: const TextStyle(
          color: Color(0xFFFFFFFF),
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    text.paint(canvas, c - Offset(text.width / 2, text.height / 2));
    text.dispose();
  }

  @override
  bool shouldRepaint(_CheckPainter oldDelegate) => oldDelegate.order != order;
}

// The shots counter: bold white text with a chevron 4 after it, 16 in from
// each side, in a pill 38 high outlined white 2 thick over a soft shadow.
class _ShotsCounter extends StatelessWidget {
  const _ShotsCounter({required this.text, required this.onTap, super.key});

  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: text,
    onTap: onTap,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(19),
          border: Border.all(color: const Color(0xFFFFFFFF), width: 2),
          boxShadow: const [BoxShadow(color: Color(0x1F000000), blurRadius: 5)],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              text,
              style: const TextStyle(
                color: Color(0xFFFFFFFF),
                fontSize: 14,
                fontWeight: FontWeight.bold,
                decoration: TextDecoration.none,
              ),
            ),
            const SizedBox(width: 4),
            const CustomPaint(size: Size(8, 12), painter: _ChevronPainter()),
          ],
        ),
      ),
    ),
  );
}

class _ChevronPainter extends CustomPainter {
  const _ChevronPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(
      Path()
        ..moveTo(2, 1)
        ..lineTo(size.width - 2, size.height / 2)
        ..lineTo(2, size.height - 1),
      p,
    );
  }

  @override
  bool shouldRepaint(_ChevronPainter oldDelegate) => false;
}

// While a recording runs, a control fades out over 250 ms and takes no
// touches; it comes back the same way.
class _FadeWhileRecording extends StatelessWidget {
  const _FadeWhileRecording({
    required this.recording,
    required this.child,
    super.key,
  });

  final bool recording;
  final Widget child;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: recording,
    child: AnimatedOpacity(
      opacity: recording ? 0 : 1,
      duration: const Duration(milliseconds: 250),
      child: child,
    ),
  );
}

// The shots taken so far, oldest first: 56 tiles 4 apart, each with a
// remove button at its top end.
class _ResultsStrip extends StatelessWidget {
  const _ResultsStrip({
    required this.shots,
    required this.builder,
    required this.onRemove,
    super.key,
  });

  final List<CameraShot> shots;
  final Widget Function(BuildContext context, CameraShot shot)? builder;
  final ValueChanged<CameraShot> onRemove;

  @override
  Widget build(BuildContext context) => ListView(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.symmetric(horizontal: 4),
    children: [
      for (final shot in shots)
        Padding(
          key: ValueKey(('mpx-capture-result', shot.key ?? shot.output.path)),
          padding: const EdgeInsetsDirectional.only(end: 4),
          child: SizedBox.square(
            dimension: 56,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child:
                      builder?.call(context, shot) ??
                      const ColoredBox(color: Color(0x66FFFFFF)),
                ),
                PositionedDirectional(
                  top: 2,
                  end: 2,
                  child: GestureDetector(
                    key: const ValueKey('mpx-capture-result-remove'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => onRemove(shot),
                    child: const SizedBox.square(
                      dimension: 18,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Color(0x99000000),
                          shape: BoxShape.circle,
                        ),
                        child: CustomPaint(painter: _CrossPainter()),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
    ],
  );
}

class _CrossPainter extends CustomPainter {
  const _CrossPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final p = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    canvas
      ..drawLine(c + const Offset(-4, -4), c + const Offset(4, 4), p)
      ..drawLine(c + const Offset(4, -4), c + const Offset(-4, 4), p);
  }

  @override
  bool shouldRepaint(_CrossPainter oldDelegate) => false;
}

// The zoom slider: minus and plus 41 from the ends, the track between them
// 18 in from each, 6 thick; the knob drags the zoom, a tap on the track
// (moved 10 at most) jumps there, minus and plus step a quarter.
class _ZoomSlider extends StatefulWidget {
  const _ZoomSlider({
    required this.zoom,
    required this.onZoom,
    required this.onStep,
    super.key,
  });

  final double zoom;
  final ValueChanged<double> onZoom;
  final ValueChanged<int> onStep;

  @override
  State<_ZoomSlider> createState() => _ZoomSliderState();
}

enum _ZoomPress { knob, minus, plus, track }

class _ZoomSliderState extends State<_ZoomSlider> {
  static const double _end = 41;
  static const double _inset = 18;

  _ZoomPress? _press;
  double _from = 0;

  static (double, double) _track(double width) =>
      (_end + _inset, width - _end - _inset);

  void _down(PointerDownEvent event, Size size) {
    final p = event.localPosition;
    final (start, end) = _track(size.width);
    final cy = size.height / 2;
    final knob = start + (end - start) * widget.zoom.clamp(0.0, 1.0);
    if ((p.dx - knob).abs() <= 20 && (p.dy - cy).abs() <= 25) {
      _press = _ZoomPress.knob;
      _from = p.dx - knob;
    } else if ((p.dx - _end).abs() <= 16 && (p.dy - cy).abs() <= 16) {
      _press = _ZoomPress.minus;
    } else if ((p.dx - (size.width - _end)).abs() <= 16 &&
        (p.dy - cy).abs() <= 16) {
      _press = _ZoomPress.plus;
    } else if (p.dx >= start && p.dx <= end) {
      _press = _ZoomPress.track;
      _from = p.dx;
    } else {
      _press = null;
    }
    setState(() {});
  }

  void _move(PointerMoveEvent event, Size size) {
    if (_press != _ZoomPress.knob) return;
    final (start, end) = _track(size.width);
    widget.onZoom((event.localPosition.dx - _from - start) / (end - start));
  }

  void _up(PointerUpEvent event, Size size) {
    final (start, end) = _track(size.width);
    final x = event.localPosition.dx;
    switch (_press) {
      case _ZoomPress.minus:
        widget.onStep(-1);
      case _ZoomPress.plus:
        widget.onStep(1);
      case _ZoomPress.track when (x - _from).abs() <= 10:
        widget.onZoom((x - start) / (end - start));
      case _:
    }
    setState(() => _press = null);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
      return Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) => _down(e, size),
        onPointerMove: (e) => _move(e, size),
        onPointerUp: (e) => _up(e, size),
        onPointerCancel: (_) => setState(() => _press = null),
        child: CustomPaint(
          size: size,
          painter: _ZoomSliderPainter(
            zoom: widget.zoom,
            pressed: _press == _ZoomPress.knob,
          ),
        ),
      );
    },
  );
}

class _ZoomSliderPainter extends CustomPainter {
  const _ZoomSliderPainter({required this.zoom, required this.pressed});

  final double zoom;
  final bool pressed;

  @override
  void paint(Canvas canvas, Size size) {
    const end = _ZoomSliderState._end;
    final (start, stop) = _ZoomSliderState._track(size.width);
    final cy = size.height / 2;
    final white = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final plus = size.width - end;
    // Minus and plus, 14 across.
    canvas
      ..drawLine(Offset(end - 7, cy), Offset(end + 7, cy), white)
      ..drawLine(Offset(plus - 7, cy), Offset(plus + 7, cy), white)
      ..drawLine(Offset(plus, cy - 7), Offset(plus, cy + 7), white);
    final knob = start + (stop - start) * zoom.clamp(0.0, 1.0);
    const round = Radius.circular(3);
    canvas
      ..drawRRect(
        RRect.fromLTRBR(start, cy - 3, stop, cy + 3, round),
        Paint()..color = const Color(0x66FFFFFF),
      )
      ..drawRRect(
        RRect.fromLTRBR(start, cy - 3, knob, cy + 3, round),
        Paint()..color = const Color(0xFFFFFFFF),
      )
      ..drawCircle(
        Offset(knob, cy),
        // The knob image's disc: 12 across, 16.7 pressed (the pressed image
        // is 20 with a 50/60 disc).
        pressed ? 50 / 60 * 10 : 6,
        Paint()..color = const Color(0xFFFFFFFF),
      );
  }

  @override
  bool shouldRepaint(_ZoomSliderPainter oldDelegate) =>
      oldDelegate.zoom != zoom || oldDelegate.pressed != pressed;
}

class _Shutter extends StatefulWidget {
  const _Shutter({
    required this.style,
    required this.holdToRecord,
    required this.videoMode,
    required this.label,
    required this.recording,
    required this.enabled,
    required this.onTap,
    required this.onHoldStart,
    required this.onHoldMove,
    required this.onHoldEnd,
  });

  final void Function(Offset local, Offset fromPress) onHoldMove;
  final CaptureShutterStyle style;
  final Duration holdToRecord;
  final bool videoMode;
  final String label;
  final bool recording;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onHoldStart;
  final VoidCallback onHoldEnd;

  @override
  State<_Shutter> createState() => _ShutterState();
}

// Pressed, the shutter grows to 1.06 over 120 ms, decelerating; released,
// it settles back the same way after 40 ms.
class _ShutterState extends State<_Shutter> with TickerProviderStateMixin {
  late final AnimationController _press;
  // The square style's colour (white to red) and shape (disc to square),
  // each over 250 ms.
  late final AnimationController _red;
  late final AnimationController _square;
  Timer? _release;

  @override
  void initState() {
    super.initState();
    _press = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
    );
    _red = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
      value: widget.videoMode || widget.recording ? 1 : 0,
    );
    _square = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
      value: widget.recording ? 1 : 0,
    );
  }

  @override
  void didUpdateWidget(_Shutter oldWidget) {
    super.didUpdateWidget(oldWidget);
    final red = widget.videoMode || widget.recording;
    if (red != (oldWidget.videoMode || oldWidget.recording)) {
      (red ? _red.forward() : _red.reverse()).ignore();
    }
    if (widget.recording != oldWidget.recording) {
      (widget.recording ? _square.forward() : _square.reverse()).ignore();
    }
  }

  @override
  void dispose() {
    _release?.cancel();
    _press.dispose();
    _red.dispose();
    _square.dispose();
    super.dispose();
  }

  void _down(PointerDownEvent _) {
    if (!widget.enabled || widget.style != CaptureShutterStyle.dot) return;
    _release?.cancel();
    _press.forward().ignore();
  }

  void _up(PointerEvent _) {
    _release?.cancel();
    _release = Timer(const Duration(milliseconds: 40), () {
      if (mounted) _press.reverse().ignore();
    });
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    return Semantics(
      key: const ValueKey('mpx-capture-shutter'),
      button: true,
      enabled: enabled,
      label: widget.label,
      onTap: enabled ? widget.onTap : null,
      child: Listener(
        onPointerDown: _down,
        onPointerUp: _up,
        onPointerCancel: _up,
        child: RawGestureDetector(
          behavior: HitTestBehavior.opaque,
          gestures: {
            if (enabled)
              TapGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                    TapGestureRecognizer.new,
                    (tap) => tap.onTap = widget.onTap,
                  ),
            if (enabled)
              LongPressGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<
                    LongPressGestureRecognizer
                  >(
                    () => LongPressGestureRecognizer(
                      duration: widget.holdToRecord,
                    ),
                    (hold) => hold
                      ..onLongPressStart = ((_) => widget.onHoldStart())
                      ..onLongPressMoveUpdate = ((details) => widget.onHoldMove(
                        details.localPosition,
                        details.offsetFromOrigin,
                      ))
                      ..onLongPressEnd = ((_) => widget.onHoldEnd()),
                  ),
          },
          child: AnimatedBuilder(
            animation: _press,
            builder: (context, child) => Transform.scale(
              scale: 1 + 0.06 * Curves.decelerate.transform(_press.value),
              child: child,
            ),
            child: switch (widget.style) {
              CaptureShutterStyle.dot => SizedBox.square(
                dimension: 76,
                child: CustomPaint(
                  painter: _ShutterPainter(
                    recording: widget.recording,
                    enabled: enabled,
                  ),
                ),
              ),
              CaptureShutterStyle.square => AnimatedBuilder(
                animation: Listenable.merge([_red, _square]),
                builder: (context, _) => SizedBox.square(
                  dimension: 72,
                  child: CustomPaint(
                    painter: CaptureSquareShutterPainter(
                      video: _red.value,
                      recording: Curves.easeOut.transform(_square.value),
                      enabled: enabled,
                    ),
                  ),
                ),
              ),
            },
          ),
        ),
      ),
    );
  }
}

class _ShutterPainter extends CustomPainter {
  const _ShutterPainter({required this.recording, required this.enabled});

  final bool recording;
  final bool enabled;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    final white = Color(enabled ? 0xFFFFFFFF : 0x80FFFFFF);
    canvas.drawCircle(
      center,
      radius - 3,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..color = white,
    );
    canvas.drawCircle(
      center,
      recording ? radius * 0.45 : radius - 10,
      Paint()..color = recording ? const Color(0xFFFF3B30) : white,
    );
  }

  @override
  bool shouldRepaint(_ShutterPainter old) =>
      old.recording != recording || old.enabled != enabled;
}

enum _Glyph { close, flashOff, flashAuto, flashOn, switchCamera }

class _GlyphButton extends StatelessWidget {
  const _GlyphButton({
    required this.glyph,
    required this.label,
    required this.onTap,
    this.value,
    this.swap,
    super.key,
  });

  final _Glyph glyph;
  final String label;
  final String? value;
  final VoidCallback onTap;

  // With a duration, a new glyph swaps in over it: the old one goes 48
  // down and fades, the new one comes from 48 above.
  final Duration? swap;

  @override
  Widget build(BuildContext context) {
    final picture = CustomPaint(
      key: ValueKey(glyph),
      painter: _GlyphPainter(glyph),
    );
    return Semantics(
      button: true,
      label: label,
      value: value,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox.square(
          dimension: 48,
          child: switch (swap) {
            null => picture,
            final swap => ClipRect(
              child: AnimatedSwitcher(
                duration: swap,
                switchInCurve: const Cubic(0.25, 0.1, 0.25, 1),
                switchOutCurve: const Cubic(0.25, 0.1, 0.25, 1),
                layoutBuilder: (current, previous) => Stack(
                  fit: StackFit.expand,
                  children: [...previous, ?current],
                ),
                transitionBuilder: (child, animation) {
                  final incoming = child.key == ValueKey(glyph);
                  return AnimatedBuilder(
                    animation: animation,
                    child: child,
                    builder: (context, child) => Transform.translate(
                      offset: Offset(
                        0,
                        (incoming ? -48 : 48) * (1 - animation.value),
                      ),
                      child: Opacity(opacity: animation.value, child: child),
                    ),
                  );
                },
                child: picture,
              ),
            ),
          },
        ),
      ),
    );
  }
}

// Glyphs drawn with strokes, so the package needs no icon font.
class _GlyphPainter extends CustomPainter {
  const _GlyphPainter(this.glyph);

  final _Glyph glyph;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final c = size.center(Offset.zero);
    const r = 10.0;
    switch (glyph) {
      case _Glyph.close:
        canvas
          ..drawLine(c + const Offset(-r, -r), c + const Offset(r, r), paint)
          ..drawLine(c + const Offset(r, -r), c + const Offset(-r, r), paint);
      case _Glyph.flashOff || _Glyph.flashAuto || _Glyph.flashOn:
        final bolt = Path()
          ..moveTo(c.dx + 2, c.dy - r - 2)
          ..lineTo(c.dx - 6, c.dy + 1)
          ..lineTo(c.dx, c.dy + 1)
          ..lineTo(c.dx - 2, c.dy + r + 2)
          ..lineTo(c.dx + 6, c.dy - 1)
          ..lineTo(c.dx, c.dy - 1)
          ..close();
        if (glyph == _Glyph.flashOn) {
          canvas.drawPath(bolt, Paint()..color = const Color(0xFFFFD60A));
        } else {
          canvas.drawPath(bolt, paint);
        }
        if (glyph == _Glyph.flashOff) {
          canvas.drawLine(
            c + const Offset(-r, -r),
            c + const Offset(r, r),
            paint,
          );
        }
        if (glyph == _Glyph.flashAuto) {
          canvas.drawCircle(
            c + const Offset(r, -r + 2),
            3,
            Paint()..color = const Color(0xFFFFFFFF),
          );
        }
      case _Glyph.switchCamera:
        final rect = Rect.fromCircle(center: c, radius: r);
        canvas
          ..drawArc(rect, -math.pi * 0.9, math.pi * 0.8, false, paint)
          ..drawArc(rect, math.pi * 0.1, math.pi * 0.8, false, paint);
        final tip =
            c +
            Offset(r * math.cos(-0.1 * math.pi), r * math.sin(-0.1 * math.pi));
        canvas
          ..drawLine(tip, tip + const Offset(-5, -2), paint)
          ..drawLine(tip, tip + const Offset(2, -5), paint);
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => old.glyph != glyph;
}

// The route's animation eased in time both ways: going out, `ease` of the
// time gone (1 − ease(1 − t)), so the close runs the same curve as the
// open, from its own start.
class _EasedInTime extends Animation<double>
    with AnimationWithParentMixin<double> {
  _EasedInTime(this.parent);

  @override
  final Animation<double> parent;

  @override
  double get value {
    final t = parent.value;
    return switch (parent.status) {
      AnimationStatus.reverse => 1 - Curves.ease.transform(1 - t),
      _ => Curves.ease.transform(t),
    };
  }
}

class _FocusRing extends CustomPainter {
  const _FocusRing(this.t);

  // 0 to 1 over the ring's 500 ms: 200 to close in, 150 for the disc to
  // fade, 150 for the ring.
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    const curve = Curves.decelerate;
    const base = 30.0;
    final ms = t * 500;
    final closing = curve.transform((ms / 200).clamp(0.0, 1.0));
    final inner = 1 - ((ms - 200) / 150).clamp(0.0, 1.0);
    final outer = 1 - ((ms - 350) / 150).clamp(0.0, 1.0);
    final c = size.center(Offset.zero);
    canvas
      ..drawCircle(
        c,
        base + base * (1 - closing),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Color.fromRGBO(255, 255, 255, curve.transform(outer)),
      )
      ..drawCircle(
        c,
        base * closing,
        Paint()
          ..color = Color.fromRGBO(255, 255, 255, curve.transform(inner) * 0.5),
      );
  }

  @override
  bool shouldRepaint(_FocusRing oldDelegate) => oldDelegate.t != t;
}

// Android's DecelerateInterpolator: 1 − (1 − t)^(2 × factor).
class _Decelerate extends Curve {
  const _Decelerate(this.factor);

  final double factor;

  @override
  double transformInternal(double t) =>
      1 - math.pow(1 - t, 2 * factor).toDouble();
}
