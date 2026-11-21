import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// The edge auto-scroll of a drag held near a scrollable's top or bottom
/// (a swipe selection), headless: a host can drive it under its own grid.
///
/// The finger is kept in screen coordinates. While a held finger does not
/// move no pointer event comes, yet the scrollable may move under it (a
/// sheet rising before its content scrolls): measured against the
/// scrollable each frame, a finger kept in the scrollable's own coordinates
/// would ride up with it, out of the band, and the auto-scroll would stop
/// after the first few steps.
///
/// Each frame the finger is within [edge] of the scrollable's part on
/// screen ([viewport]), it scrolls [position] toward that end by up to
/// [maxStep], the deeper the faster, as a drag of the list (so a host's
/// position, a sheet that rises before its content scrolls, takes each step
/// as a user scroll), and tells [onStep] where the finger is.
final class EdgeAutoScroll {
  /// Creates the auto-scroll, ticking on [vsync].
  EdgeAutoScroll({
    required TickerProvider vsync,
    required this.position,
    required this.viewport,
    this.edge = 60,
    this.maxStep = 16,
    this.onStep,
  }) {
    _ticker = vsync.createTicker((_) => tick());
  }

  /// The position scrolled; null while the scrollable has none.
  final ScrollPosition? Function() position;

  /// The scrollable's part on screen, in global coordinates; null while it
  /// is not laid out.
  final Rect? Function() viewport;

  /// How deep the bands at each end are.
  final double edge;

  /// The most it scrolls a frame, with the finger at the very end.
  final double maxStep;

  /// Told the finger (global) after each step, so the host extends what
  /// the drag covers under it.
  final ValueChanged<Offset>? onStep;

  late final Ticker _ticker;
  Offset? _finger;
  Drag? _drag;

  /// Where the finger is, in global coordinates; null when not held.
  Offset? get finger => _finger;

  /// Whether it is scrolling (the finger in a band).
  bool get active => _ticker.isActive;

  /// How far a finger at [y] scrolls a frame toward the near end of a
  /// viewport from [top] to [bottom], as a share of the most (-1 to 1):
  /// nothing outside the bands.
  static double depthOf(
    double y, {
    required double top,
    required double bottom,
    required double edge,
  }) {
    if (y < top + edge) return -((top + edge - y) / edge).clamp(0.0, 1.0);
    if (y > bottom - edge)
      return ((y - (bottom - edge)) / edge).clamp(0.0, 1.0);
    return 0;
  }

  /// The finger is at [global]: it starts scrolling in a band and stops
  /// outside one.
  void hold(Offset global) {
    _finger = global;
    final near = _depth() != 0;
    if (near && !_ticker.isActive) {
      _ticker.start().ignore();
    } else if (!near && _ticker.isActive) {
      _stop();
    }
  }

  /// The finger let go: the scroll stops, at rest.
  void release() {
    _finger = null;
    _stop();
  }

  /// One frame's step; the ticker calls it, and a test may.
  @visibleForTesting
  void tick() {
    final finger = _finger;
    final scroll = position();
    if (finger == null || scroll == null) return;
    final depth = _depth();
    if (depth == 0) return;
    final step = depth * maxStep;
    final drag = _drag ??= scroll.drag(
      DragStartDetails(globalPosition: finger),
      () => _drag = null,
    );
    drag.update(
      DragUpdateDetails(
        globalPosition: finger,
        delta: Offset(0, -step),
        primaryDelta: -step,
      ),
    );
    onStep?.call(finger);
  }

  double _depth() {
    final finger = _finger;
    final rect = viewport();
    if (finger == null || rect == null) return 0;
    return depthOf(finger.dy, top: rect.top, bottom: rect.bottom, edge: edge);
  }

  void _stop() {
    if (_ticker.isActive) _ticker.stop();
    _drag?.end(DragEndDetails(primaryVelocity: 0));
    _drag = null;
  }

  /// Lets go of the ticker; a drag under way is cancelled, its list going
  /// away with it.
  void dispose() {
    _drag?.cancel();
    _drag = null;
    _ticker.dispose();
  }
}
