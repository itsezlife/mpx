import 'dart:math' as math;

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

  /// The drag ended at [offset].
  final ValueChanged<double> onEnd;
}

/// One page of the viewer: the picture fitted into the page, zoomed by pinch
/// and double tap within the policy's range, panned within its bounds, and
/// dragged vertically to dismiss while it is not zoomed.
class ViewerPhotoPage extends StatefulWidget {
  /// Creates a page drawing [child] in a box of [contentSize], centred.
  const ViewerPhotoPage({
    required this.child,
    required this.contentSize,
    required this.policy,
    required this.drag,
    required this.onZoomedChanged,
    super.key,
    this.onTap,
  });

  /// The picture.
  final Widget child;

  /// The size the picture is drawn at when not zoomed.
  final Size contentSize;

  /// The rules.
  final ViewerPolicy policy;

  /// Where dismiss drags go.
  final ViewerDragEvents drag;

  /// Told when the page leaves or returns to its resting zoom, so the viewer
  /// stops paging while a picture is zoomed.
  final ValueChanged<bool> onZoomedChanged;

  /// A single tap on the page.
  final VoidCallback? onTap;

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
    if (wasZoomed != _zoomed) widget.onZoomedChanged(_zoomed);
  }

  // How far the picture may move from the centre at [zoom], per axis.
  Offset _bounds(double zoom) {
    final size = widget.contentSize;
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
    if (_zoom != policy.minZoom) {
      _animateTo(policy.minZoom, Offset.zero);
      return;
    }
    final target = policy.doubleTapZoom;
    final pan = _panAround(_fromCentre(at), _zoom, _pan, target);
    _animateTo(target, _clampPan(pan, target));
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
      if (!_dismissing && policy.startsDismiss(moved.dx, moved.dy)) {
        _dismissing = true;
        _dismissFrom = moved.dy;
        widget.drag.onStart();
      }
      if (_dismissing) widget.drag.onUpdate(moved.dy - _dismissFrom);
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
      widget.drag.onEnd(_lastFocal.dy - _startFocal.dy - _dismissFrom);
      return;
    }
    final zoom = widget.policy.settleZoom(_zoom);
    final pan = zoom == 1 ? Offset.zero : _clampPan(_pan, zoom);
    if (zoom != _zoom || pan != _pan) _animateTo(zoom, pan);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _pageSize = constraints.biggest;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
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
            child: SizedBox.fromSize(
              size: widget.contentSize,
              child: widget.child,
            ),
          ),
        ),
      );
    },
  );
}
