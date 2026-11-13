import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
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

/// One page of the viewer: the picture fitted into the page, zoomed by pinch
/// and double tap within [maxZoom], panned within its bounds, and dragged
/// vertically to dismiss while it is not zoomed. A video page passes
/// [onDoubleTap] to seek instead of zooming, and [onHoldStart] /
/// [onHoldEnd] for a held press.
///
/// It works on its own inside a host's pager or screen with the policy's
/// gestures: without [drag] there is no dismiss drag, and a host pager
/// stops paging while [onZoomedChanged] says the picture is zoomed.
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

  /// Where dismiss drags go; no dismiss drag when null.
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
  final void Function(Offset local, Size page)? onHoldStart;

  /// The held press ended.
  final VoidCallback? onHoldEnd;

  @override
  State<ViewerPhotoPage> createState() => ViewerPhotoPageState();
}

/// The state of a [ViewerPhotoPage]; its zoom and pan are readable for tests
/// and for the chrome.
class ViewerPhotoPageState extends State<ViewerPhotoPage>
    with SingleTickerProviderStateMixin {
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

  // The gesture in progress.
  double _startZoom = 1;
  Offset _startPan = Offset.zero;
  Offset _startFocal = Offset.zero;
  Offset _lastFocal = Offset.zero;
  bool _dismissing = false;
  double _dismissFrom = 0;
  Offset? _doubleTapAt;
  Size _pageSize = Size.zero;

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
  }

  @override
  void dispose() {
    _settle.dispose();
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
    _settleFromZoom = _zoom;
    _settleFromPan = _pan;
    _settleToZoom = zoom;
    _settleToPan = pan;
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

  void _onDoubleTap() {
    final at = _doubleTapAt;
    if (at == null) return;
    final policy = widget.policy;
    final inset = policy.doubleTapEdgeInset;
    if (at.dx < inset ||
        at.dy < inset ||
        at.dx > _pageSize.width - inset ||
        at.dy > _pageSize.height - inset) {
      return;
    }
    if (widget.onDoubleTap?.call(at, _pageSize) ?? false) return;
    if (_zoom != policy.minZoom) {
      _animateTo(policy.minZoom, Offset.zero);
      return;
    }
    final target = widget.doubleTapZoom;
    if (target == null) return;
    final pan = _panAround(_fromCentre(at), _zoom, _pan, target);
    _animateTo(target, _clampPan(pan, target));
  }

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

  void _onTapUp(TapUpDetails details) {
    final background = widget.onBackgroundTap;
    if (background != null && !_onPicture(details.localPosition)) {
      background();
    } else {
      widget.onTap?.call();
    }
  }

  void _onScaleStart(ScaleStartDetails details) {
    _settle.stop();
    _startZoom = _zoom;
    _startPan = _pan;
    _startFocal = _fromCentre(details.localFocalPoint);
    _lastFocal = _startFocal;
    _dismissing = false;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final focal = _fromCentre(details.localFocalPoint);
    final moved = focal - _startFocal;
    final policy = widget.policy;
    if (details.pointerCount < 2 && _startZoom == 1 && !_zoomed) {
      final drag = widget.drag;
      if (drag != null &&
          !_dismissing &&
          policy.startsDismiss(moved.dx, moved.dy)) {
        _dismissing = true;
        _dismissFrom = moved.dy;
        drag.onStart();
      }
      if (_dismissing) drag?.onUpdate(moved.dy - _dismissFrom);
      _lastFocal = focal;
      return;
    }
    if (_dismissing) return;
    final zoom = _startZoom * details.scale;
    var pan = _panAround(_startFocal, _startZoom, _startPan, zoom) + moved;
    // Past the edge the pan follows only partly.
    final bounds = _bounds(zoom);
    double damp(double value, double bound) {
      if (value.abs() <= bound) return value;
      final over = value.abs() - bound;
      return value.sign * (bound + over * policy.overPanDamping);
    }

    pan = Offset(damp(pan.dx, bounds.dx), damp(pan.dy, bounds.dy));
    _lastFocal = focal;
    _set(zoom, pan);
  }

  void _onScaleEnd(ScaleEndDetails details) {
    if (_dismissing) {
      _dismissing = false;
      widget.drag?.onEnd(
        _lastFocal.dy - _startFocal.dy - _dismissFrom,
        details.velocity.pixelsPerSecond.dy,
      );
      return;
    }
    final zoom = widget.policy.settleZoom(_zoom, max: _maxZoom);
    final pan = zoom == 1 ? Offset.zero : _clampPan(_pan, zoom);
    if (zoom != _zoom || pan != _pan) _animateTo(zoom, pan);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _pageSize = constraints.biggest;
      Widget page = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: _onTapUp,
        onDoubleTapDown: (details) => _doubleTapAt = details.localPosition,
        onDoubleTap: _onDoubleTap,
        onScaleStart: _onScaleStart,
        onScaleUpdate: _onScaleUpdate,
        onScaleEnd: _onScaleEnd,
        child: Center(
          child: Transform(
            alignment: Alignment.center,
            transform: Matrix4.translationValues(_pan.dx, _pan.dy, 0)
              ..scaleByDouble(_zoom, _zoom, 1, 1),
            child: SizedBox.fromSize(size: _contentSize, child: widget.child),
          ),
        ),
      );
      final delay = widget.holdDelay;
      if (delay != null) {
        page = RawGestureDetector(
          behavior: HitTestBehavior.opaque,
          gestures: {
            LongPressGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<
                  LongPressGestureRecognizer
                >(() => LongPressGestureRecognizer(duration: delay), (
                  recognizer,
                ) {
                  recognizer
                    ..onLongPressStart = (details) {
                      widget.onHoldStart?.call(
                        details.localPosition,
                        _pageSize,
                      );
                    }
                    ..onLongPressEnd = (_) {
                      widget.onHoldEnd?.call();
                    };
                }),
          },
          child: page,
        );
      }
      return page;
    },
  );
}
