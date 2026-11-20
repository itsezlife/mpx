import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:mpx_ui/src/gallery/gallery_page_gestures.dart';
import 'package:mpx_ui/src/gallery/gallery_pager_physics.dart';

/// What a gallery's gesture is, once decided.
enum GalleryDragPhase {
  /// No gesture, or one not decided yet.
  idle,

  /// A page drag along the pager's axis.
  paging,

  /// A dismiss drag across it.
  dismissing,

  /// A pan of the zoomed picture (handing on to the pager at its edge).
  panning,

  /// A pinch.
  pinching,
}

/// Where a [GalleryGestureRecognizer] sends the gesture it decided.
abstract interface class GalleryDragTarget {
  /// The pager's axis.
  Axis get axis;

  /// When a drag along the axis pages.
  GalleryClaim get pageClaim;

  /// When a drag across the axis dismisses; null for no dismiss.
  GalleryClaim? get dismissClaim;

  /// The page the pager rests on, or null.
  GalleryPageGestures? get page;

  /// Whether touches are ignored now (a settle that touches do not catch).
  bool get ignoresTouch;

  /// Whether a pinch may start: the pager is at rest, no neighbour shows.
  bool get canPinch;

  /// A touch came down; true when it caught a running settle, so the drag
  /// is the pager's at once.
  bool down();

  /// A page drag started.
  void pageStart();

  /// The page drag moved by [delta] along the axis, screen-space.
  void pageUpdate(double delta);

  /// The page drag ended with [velocity] along the axis, screen-space.
  void pageEnd(double velocity);

  /// A pan of the zoomed picture started.
  void panStart();

  /// The pan moved by [delta].
  void panUpdate(Offset delta);

  /// The pan ended with [velocity].
  void panEnd(Offset velocity);

  /// A dismiss drag started.
  void dismissStart();

  /// The dismiss drag is [offset] across the axis from where it started.
  void dismissUpdate(double offset);

  /// The dismiss drag ended at [offset] with [velocity] across the axis.
  void dismissEnd(double offset, double velocity);

  /// A pinch started, ended or moved: [GalleryPageGestures] has the meaning.
  void pinchStart(Offset focal);

  /// See [pinchStart].
  void pinchUpdate(double scale, Offset focal);

  /// See [pinchStart].
  void pinchEnd();
}

/// The gallery's one gesture owner: the only drag and scale recognizer over
/// the media. It decides once, on the straight line from the down point,
/// what a touch is: a pinch (a second finger, on a page that zooms, while
/// no neighbour shows), a pan of a zoomed picture, a dismiss drag (tested
/// first, by [GalleryDragTarget.dismissClaim]) or a page drag (by
/// [GalleryDragTarget.pageClaim]); the first that holds locks for the
/// gesture. The distance that decided it is swallowed, so the picture
/// does not jump.
///
/// A stock scale recognizer accepts on the first slop in any direction and
/// races the pager's drag recognizer for the arena: a vertical swipe could
/// start the page, and a zoomed picture's edge could never hand on to the
/// pager. Here one recognizer runs the whole decision, and the hand-off
/// (what the zoomed picture does not take at its edge goes to the pager)
/// is the target's.
///
/// A touch that never decides is not claimed, so the tap recognizer beside
/// it and controls deeper in the tree get it.
class GalleryGestureRecognizer extends OneSequenceGestureRecognizer {
  /// Creates the recognizer.
  GalleryGestureRecognizer({super.debugOwner, super.supportedDevices});

  /// Where the gesture goes; nothing is recognised while null.
  GalleryDragTarget? target;

  /// How far a press moves before a zoomed picture pans: the tap slop.
  double panSlop = 8;

  GalleryDragPhase _phase = GalleryDragPhase.idle;

  /// The gesture decided, or idle.
  GalleryDragPhase get phase => _phase;

  final Map<int, Offset> _positions = {};
  int? _primary;
  Offset _origin = Offset.zero;
  Offset _last = Offset.zero;
  // The offset the decision swallowed, across the axis, for the dismiss.
  double _dismissFrom = 0;
  VelocityTracker? _velocity;
  bool _ended = false;
  double _pinchSpan = 0;

  @override
  bool isPointerAllowed(PointerDownEvent event) =>
      (event.kind != PointerDeviceKind.mouse ||
          event.buttons == kPrimaryButton) &&
      super.isPointerAllowed(event);

  @override
  void addAllowedPointer(PointerDownEvent event) {
    final target = this.target;
    if (target == null) return;
    if (_primary == null) {
      if (target.ignoresTouch) return;
      _primary = event.pointer;
      _transform = event.transform;
      _phase = GalleryDragPhase.idle;
      _ended = false;
      _origin = event.position;
      _last = event.position;
      _positions[event.pointer] = event.position;
      _velocity = VelocityTracker.withKind(event.kind)
        ..addPosition(event.timeStamp, event.position);
      startTrackingPointer(event.pointer, event.transform);
      if (target.down()) _claim(GalleryDragPhase.paging);
      return;
    }
    if (_ended) return;
    _positions[event.pointer] = event.position;
    startTrackingPointer(event.pointer, event.transform);
    final page = target.page;
    final pinchable =
        _positions.length == 2 &&
        (_phase == GalleryDragPhase.idle ||
            _phase == GalleryDragPhase.panning) &&
        page != null &&
        page.canZoom &&
        target.canPinch;
    if (!pinchable) return;
    if (_phase == GalleryDragPhase.panning) target.panEnd(Offset.zero);
    _pinchSpan = _span;
    _claim(GalleryDragPhase.pinching);
    target.pinchStart(_toLocal(_focal));
  }

  // Positions go to the target in the recognizer's local space; the global
  // ones are only compared with each other.
  Matrix4? _transform;
  Offset _toLocal(Offset global) {
    final transform = _transform;
    return transform == null
        ? global
        : PointerEvent.transformPosition(transform, global);
  }

  Offset get _focal {
    var sum = Offset.zero;
    for (final position in _positions.values) {
      sum += position;
    }
    return sum / _positions.length.toDouble();
  }

  double get _span {
    final focal = _focal;
    var sum = 0.0;
    for (final position in _positions.values) {
      sum += (position - focal).distance;
    }
    return sum / _positions.length;
  }

  double _along(Offset offset, Axis axis) =>
      axis == Axis.horizontal ? offset.dx : offset.dy;

  double _across(Offset offset, Axis axis) =>
      axis == Axis.horizontal ? offset.dy : offset.dx;

  @override
  void handleEvent(PointerEvent event) {
    final target = this.target;
    if (target == null || !_positions.containsKey(event.pointer)) return;
    if (event.pointer == _primary) _transform = event.transform;
    switch (event) {
      case PointerMoveEvent(:final position):
        _positions[event.pointer] = position;
        if (event.pointer == _primary) {
          _velocity?.addPosition(event.timeStamp, position);
        }
        _moved(target, event.pointer, position);
      case PointerUpEvent() || PointerCancelEvent():
        _lifted(target, event, cancelled: event is PointerCancelEvent);
      default:
    }
  }

  void _moved(GalleryDragTarget target, int pointer, Offset position) {
    if (_ended) return;
    switch (_phase) {
      case GalleryDragPhase.pinching:
        if (_positions.length < 2 || _pinchSpan <= 0) return;
        target.pinchUpdate(_span / _pinchSpan, _toLocal(_focal));
        return;
      case _ when pointer != _primary:
        return;
      case GalleryDragPhase.idle:
        _decide(target, position);
      case GalleryDragPhase.paging:
        final delta = _along(position - _last, target.axis);
        _last = position;
        if (delta != 0) target.pageUpdate(delta);
      case GalleryDragPhase.panning:
        final delta = position - _last;
        _last = position;
        if (delta != Offset.zero) target.panUpdate(delta);
      case GalleryDragPhase.dismissing:
        _last = position;
        target.dismissUpdate(
          _across(position - _origin, target.axis) - _dismissFrom,
        );
    }
  }

  void _decide(GalleryDragTarget target, Offset position) {
    final offset = position - _origin;
    final axis = target.axis;
    final page = target.page;
    if (page != null && page.isZoomed) {
      if (offset.distance <= panSlop) return;
      _last = position;
      _claim(GalleryDragPhase.panning);
      target.panStart();
      return;
    }
    final along = _along(offset, axis);
    final across = _across(offset, axis);
    final dismiss = target.dismissClaim;
    if (dismiss != null && dismiss.claims(across, along)) {
      _dismissFrom = across;
      _last = position;
      _claim(GalleryDragPhase.dismissing);
      target.dismissStart();
      return;
    }
    if (target.pageClaim.claims(along, across)) {
      _last = position;
      _claim(GalleryDragPhase.paging);
    }
  }

  void _claim(GalleryDragPhase phase) {
    final caught = phase == GalleryDragPhase.paging;
    _phase = phase;
    resolve(GestureDisposition.accepted);
    if (caught) target?.pageStart();
  }

  void _lifted(
    GalleryDragTarget target,
    PointerEvent event, {
    required bool cancelled,
  }) {
    final pointer = event.pointer;
    _positions.remove(pointer);
    if (!_ended) {
      if (_phase == GalleryDragPhase.pinching) {
        if (_positions.length < 2) {
          target.pinchEnd();
          // The finger left keeps panning a picture the pinch zoomed, but
          // never flings it: its first moves are the pinch coming apart,
          // and a throw from them sends the picture off sideways.
          final page = target.page;
          if (_positions.isNotEmpty && page != null && page.isZoomed) {
            _primary = _positions.keys.first;
            _last = _positions[_primary]!;
            _velocity = null;
            _phase = GalleryDragPhase.panning;
            target.panStart();
          } else {
            _ended = true;
          }
        } else {
          _pinchSpan = _span;
        }
      } else if (pointer == _primary) {
        _end(target, cancelled: cancelled);
      }
    }
    stopTrackingPointer(pointer);
  }

  void _end(GalleryDragTarget target, {required bool cancelled}) {
    _ended = true;
    final velocity = cancelled
        ? Offset.zero
        : _velocity?.getVelocity().pixelsPerSecond ?? Offset.zero;
    switch (_phase) {
      case GalleryDragPhase.idle || GalleryDragPhase.pinching:
        break;
      case GalleryDragPhase.paging:
        target.pageEnd(_along(velocity, target.axis));
      case GalleryDragPhase.panning:
        target.panEnd(velocity);
      case GalleryDragPhase.dismissing:
        target.dismissEnd(
          _across(_last - _origin, target.axis) - _dismissFrom,
          _across(velocity, target.axis),
        );
    }
  }

  @override
  void acceptGesture(int pointer) {}

  @override
  void rejectGesture(int pointer) {
    // Another recognizer won (a control in the page, or the tap
    // recognizer's hold or double tap): the gesture is not ours.
    final target = this.target;
    if (!_ended && pointer == _primary && target != null) {
      _end(target, cancelled: true);
    }
    _positions.remove(pointer);
    stopTrackingPointer(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    if (_phase == GalleryDragPhase.idle) resolve(GestureDisposition.rejected);
    _positions.clear();
    _primary = null;
    _velocity = null;
    _phase = GalleryDragPhase.idle;
    _ended = false;
    _transform = null;
  }

  @override
  String get debugDescription => 'gallery gesture';
}
