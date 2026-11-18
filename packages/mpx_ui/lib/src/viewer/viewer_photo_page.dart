import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:mpx_ui/src/gallery/gallery_gesture_layer.dart';
import 'package:mpx_ui/src/gallery/gallery_gesture_recognizer.dart';
import 'package:mpx_ui/src/gallery/gallery_page_gestures.dart';
import 'package:mpx_ui/src/gallery/gallery_pager_physics.dart';
import 'package:mpx_ui/src/gallery/gallery_tap_recognizer.dart';
import 'package:mpx_ui/src/viewer/viewer_policy.dart';

/// What a page tells the viewer about a dismiss drag.
@immutable
final class ViewerDragEvents {
  /// Creates the callbacks.
  const ViewerDragEvents({
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
  });

  /// A dismiss drag started.
  final VoidCallback onStart;

  /// The picture is [offset] from where it rests, positive down.
  final ValueChanged<double> onUpdate;

  /// The drag ended at [offset] with a velocity of [velocity] (pixels per
  /// second, positive down).
  final void Function(double offset, double velocity) onEnd;
}

/// Answers a double tap at [local] on a page of [page] size; true when it
/// was taken (a video seeks, the window goes fullscreen) and the page must
/// not zoom.
typedef ViewerDoubleTapHandler = bool Function(Offset local, Size page);

/// Answers a press held at [local] on a page of [page] size; true when it
/// was taken (a video plays faster), and the moves until the lift are the
/// page's.
typedef ViewerHoldHandler = bool Function(Offset local, Size page);

/// One page of the viewer: the picture fitted into the page, zoomed by pinch
/// and double tap within [maxZoom], panned within its bounds, and dragged
/// vertically to dismiss while it is not zoomed. A video page passes
/// [onDoubleTap] to seek instead of zooming, and [onHoldStart] /
/// [onHoldEnd] for a held press.
///
/// Inside a `GalleryPager` the page takes its gestures from the pager's one
/// gesture owner (it is the pager's `GalleryPageGestures` for its index): a
/// pan that reaches the picture's edge goes on to the neighbouring page.
/// On its own, inside a host's pager or screen, it runs that owner itself
/// with paging off: without [drag] there is no dismiss drag, and a host
/// pager stops paging while [onZoomedChanged] says the picture is zoomed.
class ViewerPhotoPage extends StatefulWidget {
  /// Creates a page drawing [child] in a box of [contentSize], centred.
  const ViewerPhotoPage({
    required this.child,
    required this.policy,
    super.key,
    this.contentSize,
    this.drag,
    this.onZoomedChanged,
    this.maxZoom,
    this.doubleTapZoom,
    this.onTap,
    this.onBackgroundTap,
    this.onDoubleTap,
    this.holdDelay,
    this.onHoldStart,
    this.onHoldEnd,
  });

  /// The picture.
  final Widget child;

  /// The size the picture is drawn at when not zoomed; the page's size when
  /// null.
  final Size? contentSize;

  /// The rules.
  final ViewerPolicy policy;

  /// Where dismiss drags go when the page runs on its own; no dismiss drag
  /// when null. Inside a pager the pager's dismiss applies.
  final ViewerDragEvents? drag;

  /// Told when the page leaves or returns to its resting zoom, so the pager
  /// around it stops paging while a picture is zoomed.
  final ValueChanged<bool>? onZoomedChanged;

  /// The largest zoom; the policy's for the picture and the page
  /// (`ViewerPolicy.maxZoomFor`) when null.
  final double? maxZoom;

  /// The zoom a double tap goes to; null for none.
  final double? doubleTapZoom;

  /// A single tap on the picture, or anywhere when [onBackgroundTap] is
  /// null.
  final VoidCallback? onTap;

  /// A single tap beside the picture.
  final VoidCallback? onBackgroundTap;

  /// Takes a double tap before the page zooms.
  final ViewerDoubleTapHandler? onDoubleTap;

  /// How long a press is held before [onHoldStart]; null for no hold.
  final Duration? holdDelay;

  /// A press held for [holdDelay] at a point on a page of a size.
  final ViewerHoldHandler? onHoldStart;

  /// The held press ended.
  final VoidCallback? onHoldEnd;

  @override
  State<ViewerPhotoPage> createState() => ViewerPhotoPageState();
}

/// The state of a [ViewerPhotoPage]; its zoom and pan are readable for tests
/// and for the chrome.
class ViewerPhotoPageState extends State<ViewerPhotoPage>
    with TickerProviderStateMixin
    implements GalleryPageGestures {
  double _zoom = 1;
  Offset _pan = Offset.zero;

  /// The zoom now; 1 at rest.
  double get zoom => _zoom;

  /// The pan now, from the centre.
  Offset get pan => _pan;

  late final AnimationController _settle;
  double _settleFromZoom = 1;
  double _settleToZoom = 1;
  Offset _settleFromPan = Offset.zero;
  Offset _settleToPan = Offset.zero;

  // A fling of the zoomed picture: one simulation per axis, null on an axis
  // that does not fling.
  late final AnimationController _fling;
  static const Duration _flingSpan = Duration(seconds: 3);
  Simulation? _flingX;
  Simulation? _flingY;

  // The pinch in progress.
  double _startZoom = 1;
  Offset _startPan = Offset.zero;
  Offset _startFocal = Offset.zero;
  Offset _lastFocal = Offset.zero;
  Size _pageSize = Size.zero;

  GalleryPageScope? _scope;

  bool get _zoomed => _zoom != 1 || _pan != Offset.zero;

  Size get _contentSize => widget.contentSize ?? _pageSize;

  double get _maxZoom =>
      widget.maxZoom ?? widget.policy.maxZoomFor(_contentSize, _pageSize);

  @override
  void initState() {
    super.initState();
    _settle = AnimationController(
      vsync: this,
      duration: widget.policy.settleDuration,
    )..addListener(_onSettle);
    _fling = AnimationController(vsync: this, duration: _flingSpan)
      ..addListener(_onFling);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = GalleryPageScope.maybeOf(context);
    if (!identical(scope?.slot, _scope?.slot)) {
      _scope?.slot.detach(this);
      scope?.slot.attach(this);
    }
    _scope = scope;
  }

  @override
  void didUpdateWidget(ViewerPhotoPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _settle.duration = widget.policy.settleDuration;
  }

  @override
  void dispose() {
    _scope?.slot.detach(this);
    _settle.dispose();
    _fling.dispose();
    super.dispose();
  }

  void _set(double zoom, Offset pan) {
    final wasZoomed = _zoomed;
    setState(() {
      _zoom = zoom;
      _pan = pan;
    });
    if (wasZoomed != _zoomed) widget.onZoomedChanged?.call(_zoomed);
  }

  // How far the picture may move from the centre at [zoom], per axis.
  Offset _bounds(double zoom) {
    final size = _contentSize;
    return Offset(
      math.max(0, (size.width * zoom - _pageSize.width) / 2),
      math.max(0, (size.height * zoom - _pageSize.height) / 2),
    );
  }

  Offset _clampPan(Offset pan, double zoom) {
    final bounds = _bounds(zoom);
    return Offset(
      pan.dx.clamp(-bounds.dx, bounds.dx),
      pan.dy.clamp(-bounds.dy, bounds.dy),
    );
  }

  void _animateTo(double zoom, Offset pan) {
    _fling.stop();
    _settleFromZoom = _zoom;
    _settleFromPan = _pan;
    _settleToZoom = zoom;
    _settleToPan = pan;
    if (_settle.duration == Duration.zero) {
      _set(zoom, pan);
      return;
    }
    _settle.forward(from: 0);
  }

  void _onSettle() {
    final t = widget.policy.settleCurve.transform(_settle.value);
    _set(
      _settleFromZoom + (_settleToZoom - _settleFromZoom) * t,
      Offset.lerp(_settleFromPan, _settleToPan, t)!,
    );
  }

  // The pan that keeps the point [focal] (from the page's centre) under the
  // finger while the zoom goes from [fromZoom] at [fromPan] to [toZoom].
  static Offset _panAround(
    Offset focal,
    double fromZoom,
    Offset fromPan,
    double toZoom,
  ) => focal - (focal - fromPan) * (toZoom / fromZoom);

  Offset _fromCentre(Offset local) =>
      local - Offset(_pageSize.width / 2, _pageSize.height / 2);

  /// Zooms to [zoom] around [focal] (local to the page; its centre when
  /// null), animated: what the keyboard and the wheel do.
  void zoomTo(double zoom, {Offset? focal}) {
    final target = zoom.clamp(widget.policy.minZoom, _maxZoom);
    final around = focal == null ? Offset.zero : _fromCentre(focal);
    final pan = target == widget.policy.minZoom
        ? Offset.zero
        : _clampPan(_panAround(around, _zoom, _pan, target), target);
    _animateTo(target, pan);
  }

  // Whether [local] falls on the picture as it is drawn now.
  bool _onPicture(Offset local) {
    final size = _contentSize * _zoom;
    final centre = Offset(_pageSize.width / 2, _pageSize.height / 2) + _pan;
    return Rect.fromCenter(
      center: centre,
      width: size.width,
      height: size.height,
    ).contains(local);
  }

  bool _inDoubleTapInset(Offset at) {
    final inset = widget.policy.doubleTapEdgeInset;
    return at.dx < inset ||
        at.dy < inset ||
        at.dx > _pageSize.width - inset ||
        at.dy > _pageSize.height - inset;
  }

  // --- Gestures --------------------------------------------------------------

  @override
  bool get isZoomed => _zoomed;

  @override
  bool get canZoom => true;

  @override
  Duration? get holdDelay =>
      widget.onHoldStart == null ? null : widget.holdDelay;

  @override
  bool acceptsDoubleTap(Offset local) =>
      !_inDoubleTapInset(local) &&
      (widget.onDoubleTap != null ||
          widget.doubleTapZoom != null ||
          _zoom != widget.policy.minZoom);

  @override
  void stop() {
    _settle.stop();
    _fling.stop();
  }

  // Moves [from] by [delta] toward a side whose bound is [bound] (a
  // magnitude) away from the centre: free up to the bound, by the policy's
  // damping past it.
  static double _damped(
    double from,
    double delta,
    double bound,
    double damping,
  ) {
    final side = delta.sign;
    final edge = side * bound;
    final room = side > 0 ? math.max(0, edge - from) : math.min(0, edge - from);
    final free = side > 0 ? math.min(room, delta) : math.max(room, delta);
    return from + free + (delta - free) * damping;
  }

  @override
  double panBy(
    Offset delta, {
    required bool leftOpen,
    required bool rightOpen,
  }) {
    // A settle owns the picture until it lands: the finger a pinch leaves
    // waits, as a fresh touch stops the settle first (`stop`). Moving the
    // picture under the settle would fight it, and a release mid-settle
    // would aim a new one at a pan the old one was carrying.
    if (_settle.isAnimating) return 0;
    final policy = widget.policy;
    final bounds = _bounds(_zoom);
    var x = _pan.dx;
    var overflow = 0.0;
    if (delta.dx > 0 && x + delta.dx > bounds.dx) {
      if (leftOpen) {
        final taken = math.max(0, bounds.dx - x);
        overflow = delta.dx - taken;
        x = math.max(x, bounds.dx);
      } else {
        x = _damped(x, delta.dx, bounds.dx, policy.overPanDamping);
      }
    } else if (delta.dx < 0 && x + delta.dx < -bounds.dx) {
      if (rightOpen) {
        final taken = math.min(0, -bounds.dx - x);
        overflow = delta.dx - taken;
        x = math.min(x, -bounds.dx);
      } else {
        x = _damped(x, delta.dx, bounds.dx, policy.overPanDamping);
      }
    } else {
      x += delta.dx;
    }
    var y = _pan.dy + delta.dy;
    if (bounds.dy == 0 && !policy.zoomBounce) {
      // A picture shorter than the page stays centred vertically.
      y = 0;
    } else if (y.abs() > bounds.dy && delta.dy != 0) {
      y = _damped(_pan.dy, delta.dy, bounds.dy, policy.overPanDamping);
    }
    _set(_zoom, Offset(x, y));
    return overflow;
  }

  @override
  void panEnd(Offset velocity) {
    if (_settle.isAnimating) return;
    final bounds = _bounds(_zoom);
    bool inside(double value, double bound) => value.abs() <= bound + 0.5;
    final flings = widget.policy.zoomFling && velocity.distance > 50;
    Simulation? axis(double position, double speed, double bound) =>
        flings && inside(position, bound) && speed != 0 && bound > 0
        ? ClampingScrollSimulation(position: position, velocity: speed)
        : null;
    _flingX = axis(_pan.dx, velocity.dx, bounds.dx);
    _flingY = axis(_pan.dy, velocity.dy, bounds.dy);
    if (_flingX == null && _flingY == null) {
      _settleInside();
      return;
    }
    _fling.forward(from: 0);
  }

  void _onFling() {
    final seconds = _fling.value * _flingSpan.inMicroseconds / 1e6;
    final bounds = _bounds(_zoom);
    double at(Simulation? simulation, double now, double bound) =>
        simulation == null ? now : simulation.x(seconds).clamp(-bound, bound);
    final done =
        (_flingX?.isDone(seconds) ?? true) &&
        (_flingY?.isDone(seconds) ?? true);
    _set(
      _zoom,
      Offset(at(_flingX, _pan.dx, bounds.dx), at(_flingY, _pan.dy, bounds.dy)),
    );
    if (done) {
      _fling.stop();
      _settleInside();
    }
  }

  // Brings the zoom into range and the picture inside its bounds.
  void _settleInside({Offset? focal}) {
    final policy = widget.policy;
    final zoom = policy.settleZoom(_zoom, max: _maxZoom);
    var pan = _pan;
    if (zoom != _zoom && focal != null) {
      pan = _panAround(focal, _zoom, _pan, zoom);
    }
    pan = zoom <= policy.minZoom ? Offset.zero : _clampPan(pan, zoom);
    if (zoom != _zoom || pan != _pan) _animateTo(zoom, pan);
  }

  @override
  void pinchStart(Offset focal) {
    stop();
    _startZoom = _zoom;
    _startPan = _pan;
    _startFocal = _fromCentre(focal);
    _lastFocal = _startFocal;
  }

  @override
  void pinchUpdate(double scale, Offset focal) {
    final policy = widget.policy;
    var zoom = _startZoom * scale;
    if (policy.zoomBounce) {
      // Past its limits the zoom follows the fingers less and less.
      final max = _maxZoom;
      final min = policy.minZoom;
      if (zoom > max) zoom = max * math.sqrt(zoom / max);
      if (zoom < min) zoom = min * math.sqrt(zoom / min);
    }
    final at = _fromCentre(focal);
    _lastFocal = policy.zoomFocal == ViewerZoomFocal.follows ? at : _startFocal;
    var pan = _panAround(_startFocal, _startZoom, _startPan, zoom);
    if (policy.zoomFocal == ViewerZoomFocal.follows) {
      pan += at - _startFocal;
      final bounds = _bounds(zoom);
      double damp(double value, double bound) {
        if (value.abs() <= bound) return value;
        final over = value.abs() - bound;
        return value.sign * (bound + over * policy.overPanDamping);
      }

      pan = Offset(damp(pan.dx, bounds.dx), damp(pan.dy, bounds.dy));
    }
    _set(zoom, pan);
  }

  @override
  void pinchEnd() => _settleInside(focal: _lastFocal);

  @override
  void tap(Offset local) {
    final background = widget.onBackgroundTap;
    if (background != null && !_onPicture(local)) {
      background();
    } else {
      widget.onTap?.call();
    }
  }

  @override
  void doubleTap(Offset local) {
    if (_inDoubleTapInset(local)) return;
    if (widget.onDoubleTap?.call(local, _pageSize) ?? false) return;
    final policy = widget.policy;
    if (_zoom != policy.minZoom) {
      _animateTo(policy.minZoom, Offset.zero);
      return;
    }
    final target = widget.doubleTapZoom;
    if (target == null) return;
    final pan = _panAround(_fromCentre(local), _zoom, _pan, target);
    _animateTo(target, _clampPan(pan, target));
  }

  @override
  bool holdStart(Offset local) =>
      widget.onHoldStart?.call(local, _pageSize) ?? false;

  @override
  void holdMove(Offset local) {}

  @override
  void holdEnd() => widget.onHoldEnd?.call();

  @override
  void reset() {
    stop();
    if (_zoomed) _set(1, Offset.zero);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _pageSize = constraints.biggest;
      final page = Center(
        child: Transform(
          alignment: Alignment.center,
          transform: Matrix4.translationValues(_pan.dx, _pan.dy, 0)
            ..scaleByDouble(_zoom, _zoom, 1, 1),
          child: SizedBox.fromSize(size: _contentSize, child: widget.child),
        ),
      );
      if (_scope != null) return page;
      final alone = _AlonePage(this);
      return GalleryGestureLayer(
        drag: alone,
        taps: alone,
        tapRules: widget.policy.taps,
        child: page,
      );
    },
  );
}

/// A page on its own: the gallery's gesture owner with paging off, its
/// gestures all the page's, and the dismiss drag the page's [drag].
final class _AlonePage implements GalleryDragTarget, GalleryTapTarget {
  _AlonePage(this.state);

  final ViewerPhotoPageState state;

  ViewerPhotoPage get _widget => state.widget;

  @override
  Axis get axis => Axis.horizontal;

  @override
  GalleryClaim get pageClaim => const GalleryClaim.none();

  @override
  GalleryClaim? get dismissClaim =>
      _widget.drag == null ? null : _widget.policy.dismissClaim;

  @override
  GalleryPageGestures get page => state;

  @override
  bool get ignoresTouch => false;

  @override
  bool get canPinch => true;

  @override
  bool down() {
    state.stop();
    return false;
  }

  @override
  void pageStart() {}

  @override
  void pageUpdate(double delta) {}

  @override
  void pageEnd(double velocity) {}

  @override
  void panStart() {}

  @override
  void panUpdate(Offset delta) =>
      state.panBy(delta, leftOpen: false, rightOpen: false);

  @override
  void panEnd(Offset velocity) => state.panEnd(velocity);

  @override
  void dismissStart() => _widget.drag?.onStart();

  @override
  void dismissUpdate(double offset) => _widget.drag?.onUpdate(offset);

  @override
  void dismissEnd(double offset, double velocity) =>
      _widget.drag?.onEnd(offset, velocity);

  @override
  void pinchStart(Offset focal) => state.pinchStart(focal);

  @override
  void pinchUpdate(double scale, Offset focal) =>
      state.pinchUpdate(scale, focal);

  @override
  void pinchEnd() => state.pinchEnd();

  @override
  Duration? get holdDelay => state.holdDelay;

  @override
  bool acceptsDoubleTap(Offset local) => state.acceptsDoubleTap(local);

  @override
  bool sideTap(Offset local, {required bool press}) => false;

  @override
  void tap(Offset local) => state.tap(local);

  @override
  void doubleTap(Offset local) => state.doubleTap(local);

  @override
  bool holdStart(Offset local) => state.holdStart(local);

  @override
  void holdMove(Offset local) => state.holdMove(local);

  @override
  void holdEnd() => state.holdEnd();
}
