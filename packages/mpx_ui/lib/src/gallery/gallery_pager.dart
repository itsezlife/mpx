import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:mpx_ui/src/gallery/gallery_gesture_layer.dart';
import 'package:mpx_ui/src/gallery/gallery_gesture_recognizer.dart';
import 'package:mpx_ui/src/gallery/gallery_keep_alive.dart';
import 'package:mpx_ui/src/gallery/gallery_page_gestures.dart';
import 'package:mpx_ui/src/gallery/gallery_page_transition.dart';
import 'package:mpx_ui/src/gallery/gallery_pager_physics.dart';
import 'package:mpx_ui/src/gallery/gallery_tap_recognizer.dart';

// --- Controller -------------------------------------------------------------

/// The page of a [GalleryPager], and the way a host moves it.
///
/// [page] is the page the pager rests on; it changes when a settle lands,
/// as the references switch their item, so preparation keyed to it is not
/// churned by a drag that comes back. [position] is the continuous page,
/// for chrome that follows the motion. Listeners of the controller hear
/// [page] change; listeners of [position] every move.
///
/// One controller serves one pager at a time; detached, [animateTo] and
/// [jumpTo] only set [page].
class GalleryPagerController extends ChangeNotifier {
  /// A controller whose pager starts on [initialPage].
  GalleryPagerController({int initialPage = 0})
    : assert(initialPage >= 0, 'a page index is never negative'),
      _page = initialPage,
      _position = ValueNotifier(initialPage.toDouble());

  int _page;
  final ValueNotifier<double> _position;
  _GalleryPagerState? _pager;

  /// The page the pager rests on.
  int get page => _page;

  /// The continuous page.
  ValueListenable<double> get position => _position;

  /// The phase of the gesture over the pager.
  GalleryDragPhase get phase => _pager?._phase ?? GalleryDragPhase.idle;

  /// Whether a settle or a slide runs.
  bool get isSettling => _pager?._settle.isAnimating ?? false;

  /// Slides to [page] with the pager's settle (or [duration] and [curve]);
  /// a page more than one away, or a zero duration, is jumped to.
  Future<void> animateTo(int page, {Duration? duration, Curve? curve}) {
    final pager = _pager;
    if (pager == null) {
      jumpTo(page);
      return Future.value();
    }
    return pager._animateTo(page, duration: duration, curve: curve);
  }

  /// Puts the pager on [page] at once.
  void jumpTo(int page) {
    final pager = _pager;
    if (pager == null) {
      _setPage(page);
      _position.value = page.toDouble();
      return;
    }
    pager._jumpTo(page);
  }

  /// Slides to the next page, if any.
  Future<void> nextPage() => animateTo(_page + 1);

  /// Slides to the previous page, if any.
  Future<void> previousPage() => animateTo(_page - 1);

  void _setPage(int page) {
    if (page == _page) return;
    _page = page;
    notifyListeners();
  }

  @override
  void dispose() {
    _position.dispose();
    super.dispose();
  }
}

// --- Pager ------------------------------------------------------------------

/// Builds the page of [index].
typedef GalleryPageBuilder = Widget Function(BuildContext context, int index);

/// A pager for full-screen media with one gesture owner: it decides once,
/// from the down point, between a pinch, a pan of a zoomed picture, a
/// dismiss drag and a page drag ([GalleryGestureRecognizer]), with the
/// [physics] and the tap timings ([taps]) of a reference, and draws its
/// pages by a [transition].
///
/// Each page is built under a [GalleryPageScope]: a page that zooms
/// attaches its [GalleryPageGestures] there, and the pager hands the page
/// it rests on the pans, pinches and taps, and what a zoomed picture does
/// not take at its edge goes on to the neighbouring page. [onPageChanged]
/// tells a new page once its settle lands. Pages that do not show stay
/// built by [keepAlive].
///
/// Page order follows [textDirection] on a horizontal axis: right to left
/// puts the next page on the left. Null keeps left to right whatever the
/// ambient direction, as the media references do.
class GalleryPager extends StatefulWidget {
  /// Creates a pager of [count] pages.
  const GalleryPager({
    required this.count,
    required this.pageBuilder,
    super.key,
    this.controller,
    this.axis = Axis.horizontal,
    this.gap = 0,
    this.physics = GalleryPagerPhysics.$Android,
    this.transition = const GalleryPageTransition.strip(),
    this.taps = GalleryTapRules.$Android,
    this.keepAlive = const GalleryKeepAlive.around(1),
    this.dismiss,
    this.textDirection,
    this.onPageChanged,
    this.onDismissStart,
    this.onDismissUpdate,
    this.onDismissEnd,
    this.onTap,
  });

  /// How many pages there are.
  final int count;

  /// Builds a page.
  final GalleryPageBuilder pageBuilder;

  /// Moves and observes the pager; it keeps its own when null.
  final GalleryPagerController? controller;

  /// The paging axis.
  final Axis axis;

  /// The space between two pages.
  final double gap;

  /// The paging rules.
  final GalleryPagerPhysics physics;

  /// How pages are drawn between two positions.
  final GalleryPageTransition transition;

  /// The tap timings.
  final GalleryTapRules taps;

  /// Which pages stay built while they do not show.
  final GalleryKeepAlive keepAlive;

  /// When a drag across the axis dismisses; null for no dismiss drag.
  final GalleryClaim? dismiss;

  /// The page order on a horizontal axis; null for left to right.
  final TextDirection? textDirection;

  /// Told the page the pager rests on after a settle lands on a new one.
  final ValueChanged<int>? onPageChanged;

  /// A dismiss drag started.
  final VoidCallback? onDismissStart;

  /// The dismiss drag is the offset across the axis from where it started.
  final ValueChanged<double>? onDismissUpdate;

  /// The dismiss drag ended at an offset with a velocity across the axis.
  final void Function(double offset, double velocity)? onDismissEnd;

  /// A tap on a page that has no gestures of its own attached.
  final ValueChanged<Offset>? onTap;

  @override
  State<GalleryPager> createState() => _GalleryPagerState();
}

class _GalleryPagerState extends State<GalleryPager>
    with SingleTickerProviderStateMixin
    implements GalleryDragTarget, GalleryTapTarget {
  GalleryPagerController? _ownController;
  late GalleryPagerController _controller;
  late final AnimationController _settle;
  double _settleFrom = 0;
  int _settleTo = 0;
  Curve _settleCurve = Curves.linear;
  Completer<void>? _settled;

  final Map<int, GalleryPageSlot> _slots = {};
  final Set<int> _built = {};
  final Map<int, Widget> _children = {};
  Size _size = Size.zero;

  GalleryDragPhase _phase = GalleryDragPhase.idle;
  // The drag: the page it started on, and how far it moved toward the next
  // page, before the edge rule, in logical pixels.
  int _base = 0;
  double _raw = 0;
  bool _zoomedDrag = false;

  double get _extent =>
      widget.axis == Axis.horizontal ? _size.width : _size.height;

  double get _stride => _extent + widget.gap;

  // How a screen-space delta along the axis counts toward the next page.
  double get _toNext =>
      widget.axis == Axis.horizontal &&
          widget.textDirection == TextDirection.rtl
      ? 1
      : -1;

  int get _count => widget.count;

  double get _position => _controller._position.value;

  @override
  void initState() {
    super.initState();
    _settle = AnimationController(vsync: this)..addListener(_onSettleTick);
    _bind();
  }

  void _bind() {
    final controller =
        widget.controller ?? (_ownController ??= GalleryPagerController());
    _controller = controller;
    assert(
      controller._pager == null || identical(controller._pager, this),
      'A GalleryPagerController serves one pager at a time.',
    );
    controller._pager = this;
    final clamped = _clamp(controller._page);
    if (clamped != controller._page || _position != clamped) {
      controller
        .._setPage(clamped)
        .._position.value = clamped.toDouble();
    }
  }

  @override
  void didUpdateWidget(GalleryPager oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.controller, oldWidget.controller)) {
      if (identical(_controller._pager, this)) _controller._pager = null;
      _bind();
    }
    if (widget.count != oldWidget.count && _count > 0) {
      final clamped = _clamp(_controller._page);
      if (clamped != _controller._page) _jumpTo(clamped);
    }
  }

  @override
  void dispose() {
    if (identical(_controller._pager, this)) _controller._pager = null;
    _settle.dispose();
    _ownController?.dispose();
    _settled?.complete();
    super.dispose();
  }

  int _clamp(int page) => _count <= 0 ? 0 : page.clamp(0, _count - 1);

  bool _canPage(int direction) {
    final target = _controller._page + direction;
    return target >= 0 && target < _count;
  }

  // --- Settle ---------------------------------------------------------------

  Future<void> _animateTo(int page, {Duration? duration, Curve? curve}) {
    final target = _clamp(page);
    final time = duration ?? widget.physics.settleDuration;
    if (time == Duration.zero ||
        (target - _position).abs() > 1 ||
        MediaQuery.maybeDisableAnimationsOf(context) == true) {
      _jumpTo(target);
      return Future.value();
    }
    return _settleTowards(
      target,
      duration: time,
      curve: curve ?? widget.physics.settleCurve,
    );
  }

  void _jumpTo(int page) {
    _settle.stop();
    _phase = GalleryDragPhase.idle;
    _land(_clamp(page));
  }

  Future<void> _settleTowards(
    int target, {
    required Duration duration,
    required Curve curve,
  }) {
    _settle.stop();
    _settled?.complete();
    if (duration == Duration.zero || _position == target) {
      _land(target);
      return Future.value();
    }
    final settled = _settled = Completer<void>();
    _settleFrom = _position;
    _settleTo = target;
    _settleCurve = curve;
    _settle
      ..duration = duration
      ..forward(from: 0).whenCompleteOrCancel(() {
        if (_settle.value == 1) _land(target);
      });
    return settled.future;
  }

  void _onSettleTick() {
    final t = _settleCurve.transform(_settle.value);
    _controller._position.value = _settleFrom + (_settleTo - _settleFrom) * t;
  }

  void _land(int page) {
    _controller._position.value = page.toDouble();
    _zoomedDrag = false;
    if (_settled case final settled? when !settled.isCompleted) {
      settled.complete();
    }
    _settled = null;
    if (page == _controller._page) return;
    _controller._setPage(page);
    for (final MapEntry(:key, :value) in _slots.entries) {
      if (key != page) value.gestures?.reset();
    }
    widget.onPageChanged?.call(page);
    if (mounted) setState(() {});
  }

  // --- Drag target ----------------------------------------------------------

  @override
  Axis get axis => widget.axis;

  @override
  GalleryClaim get pageClaim =>
      _count > 1 ? widget.physics.claim : const GalleryClaim.none();

  @override
  GalleryClaim? get dismissClaim => widget.dismiss;

  @override
  GalleryPageGestures? get page => _slots[_controller._page]?.gestures;

  @override
  bool get ignoresTouch => _settle.isAnimating && !widget.physics.catchesSettle;

  // A neighbour showing past 5 px refuses a pinch.
  @override
  bool get canPinch =>
      _phase != GalleryDragPhase.paging &&
      (_position - _controller._page).abs() * _stride < 5;

  @override
  bool down() {
    page?.stop();
    if (!_settle.isAnimating) return false;
    // Caught mid-settle: the drag goes on from where the page is.
    _settle.stop();
    _settled?.complete();
    _settled = null;
    _base = _position.round().clamp(0, math.max(0, _count - 1));
    _raw = (_position - _base) * _stride;
    _caught = true;
    return true;
  }

  bool _caught = false;

  @override
  void pageStart() {
    _phase = GalleryDragPhase.paging;
    if (_caught) {
      _caught = false;
    } else {
      _base = _controller._page;
      _raw = 0;
    }
    _zoomedDrag = false;
  }

  @override
  void pageUpdate(double delta) {
    _raw += delta * _toNext;
    _follow();
  }

  // Moves the position by the drag: one page at most, past the ends by the
  // edge rule.
  void _follow() {
    final stride = _stride;
    if (stride <= 0) return;
    final open = _raw > 0 ? _base < _count - 1 : _base > 0;
    final pages = open
        ? (_raw / stride).clamp(-1.0, 1.0)
        : widget.physics.edge.follow(_raw, _extent) / stride;
    _controller._position.value = _base + pages;
  }

  @override
  void pageEnd(double velocity) {
    _phase = GalleryDragPhase.idle;
    final step = widget.physics.release(
      fraction: _position - _base,
      velocity: velocity * _toNext,
      canNext: _base < _count - 1,
      canPrevious: _base > 0,
      zoomed: _zoomedDrag,
    );
    unawaited(
      _settleTowards(
        _base + step,
        duration: widget.physics.settleDuration,
        curve: widget.physics.settleCurve,
      ),
    );
  }

  @override
  void panStart() {
    _phase = GalleryDragPhase.panning;
    _base = _controller._page;
    _raw = 0;
    _zoomedDrag = true;
  }

  @override
  void panUpdate(Offset delta) {
    final page = this.page;
    if (page == null) return;
    final horizontal = widget.axis == Axis.horizontal;
    final along = horizontal ? delta.dx : delta.dy;
    if (_raw != 0) {
      // The pager is off its rest: the drag brings it back first, and what
      // crosses the rest goes to the picture.
      final raw = _raw + along * _toNext;
      final crossed = raw.sign != _raw.sign;
      _raw = crossed ? 0 : raw;
      _follow();
      final rest = crossed ? raw / _toNext : 0.0;
      page.panBy(
        horizontal ? Offset(rest, delta.dy) : Offset(delta.dx, rest),
        leftOpen: false,
        rightOpen: false,
      );
      return;
    }
    final handOff = widget.physics.handOff && horizontal;
    final rtl = widget.textDirection == TextDirection.rtl;
    final overflow = page.panBy(
      delta,
      leftOpen: handOff && _canPage(rtl ? 1 : -1),
      rightOpen: handOff && _canPage(rtl ? -1 : 1),
    );
    if (overflow != 0) {
      _raw += overflow * _toNext;
      _follow();
    }
  }

  @override
  void panEnd(Offset velocity) {
    _phase = GalleryDragPhase.idle;
    if (_raw != 0) {
      page?.panEnd(Offset.zero);
      pageEnd(widget.axis == Axis.horizontal ? velocity.dx : velocity.dy);
      return;
    }
    _zoomedDrag = false;
    page?.panEnd(velocity);
  }

  @override
  void dismissStart() {
    _phase = GalleryDragPhase.dismissing;
    widget.onDismissStart?.call();
  }

  @override
  void dismissUpdate(double offset) => widget.onDismissUpdate?.call(offset);

  @override
  void dismissEnd(double offset, double velocity) {
    _phase = GalleryDragPhase.idle;
    widget.onDismissEnd?.call(offset, velocity);
  }

  @override
  void pinchStart(Offset focal) {
    _phase = GalleryDragPhase.pinching;
    page?.pinchStart(focal);
  }

  @override
  void pinchUpdate(double scale, Offset focal) =>
      page?.pinchUpdate(scale, focal);

  @override
  void pinchEnd() {
    _phase = GalleryDragPhase.idle;
    page?.pinchEnd();
  }

  // --- Tap target -----------------------------------------------------------

  @override
  Duration? get holdDelay => page?.holdDelay;

  @override
  bool acceptsDoubleTap(Offset local) => page?.acceptsDoubleTap(local) ?? false;

  @override
  bool sideTap(Offset local, {required bool press}) {
    final rule = widget.physics.sideTap;
    if (rule == null ||
        rule.onPress != press ||
        widget.axis != Axis.horizontal) {
      return false;
    }
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    var direction = rule.directionAt(local, _size, dpr);
    if (widget.textDirection == TextDirection.rtl) direction = -direction;
    if (direction == 0 || !_canPage(direction)) return false;
    _jumpTo(_controller._page + direction);
    return true;
  }

  @override
  void tap(Offset local) {
    final page = this.page;
    if (page != null) {
      page.tap(local);
    } else {
      widget.onTap?.call(local);
    }
  }

  @override
  void doubleTap(Offset local) => page?.doubleTap(local);

  @override
  bool holdStart(Offset local) => page?.holdStart(local) ?? false;

  @override
  void holdMove(Offset local) => page?.holdMove(local);

  @override
  void holdEnd() => page?.holdEnd();

  // --- Build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    _children.clear();
    return LayoutBuilder(
      builder: (context, constraints) {
        _size = constraints.biggest;
        return Semantics(
          key: const ValueKey('mpx-gallery-pager'),
          container: true,
          onScrollLeft: _semanticsStep(horizontal: true, next: !_rtl),
          onScrollRight: _semanticsStep(horizontal: true, next: _rtl),
          onScrollUp: _semanticsStep(horizontal: false, next: true),
          onScrollDown: _semanticsStep(horizontal: false, next: false),
          child: GalleryGestureLayer(
            drag: this,
            taps: this,
            tapRules: widget.taps,
            child: ClipRect(
              child: ValueListenableBuilder<double>(
                valueListenable: _controller._position,
                builder: (context, position, _) => _pages(context, position),
              ),
            ),
          ),
        );
      },
    );
  }

  bool get _rtl => widget.textDirection == TextDirection.rtl;

  VoidCallback? _semanticsStep({required bool horizontal, required bool next}) {
    if ((widget.axis == Axis.horizontal) != horizontal) return null;
    final direction = next ? 1 : -1;
    if (!_canPage(direction)) return null;
    return () => unawaited(_animateTo(_controller._page + direction));
  }

  Widget _pages(BuildContext context, double position) {
    final count = _count;
    if (count <= 0 || _size.isEmpty) return const SizedBox.expand();
    final edge = position < 0 || position > count - 1;
    final showing = <int>{
      if (edge)
        position < 0 ? 0 : count - 1
      else ...[
        position.floor().clamp(0, count - 1),
        position.ceil().clamp(0, count - 1),
      ],
    };
    final rest = _controller._page;
    _built
      ..removeWhere(
        (index) => index >= count || !widget.keepAlive.keeps(index - rest),
      )
      ..addAll(showing);
    final stride = _stride;
    final placed =
        <(int, GalleryPagePlacement)>[
          for (final index in _built)
            (
              index,
              widget.transition.place(index - position, stride, edge: edge),
            ),
        ]..sort((a, b) {
          final under = (a.$2.under ? 0 : 1) - (b.$2.under ? 0 : 1);
          return under != 0 ? under : a.$1 - b.$1;
        });
    final clips =
        widget.transition is GalleryPageTransition$Strip &&
        (widget.transition as GalleryPageTransition$Strip).parallax != 0;
    return Stack(
      fit: StackFit.expand,
      children: [
        for (final (index, placement) in placed)
          _GalleryPageFrame(
            key: ValueKey(index),
            placement: placement,
            axis: widget.axis,
            mirrored: _rtl && widget.axis == Axis.horizontal,
            shows: showing.contains(index) && placement.shows,
            interactive: index == rest,
            clips: clips,
            child: _children.putIfAbsent(
              index,
              () => GalleryPageScope(
                index: index,
                slot: _slots.putIfAbsent(index, GalleryPageSlot.new),
                child: RepaintBoundary(
                  child: widget.pageBuilder(context, index),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// One page in its place: moved, scaled and faded by its placement, offstage
/// (state kept, nothing painted) while it does not show.
class _GalleryPageFrame extends StatelessWidget {
  const _GalleryPageFrame({
    required this.placement,
    required this.axis,
    required this.mirrored,
    required this.shows,
    required this.interactive,
    required this.clips,
    required this.child,
    super.key,
  });

  final GalleryPagePlacement placement;
  final Axis axis;
  final bool mirrored;
  final bool shows;
  final bool interactive;
  final bool clips;
  final Widget child;

  Offset _along(double value) {
    final signed = mirrored ? -value : value;
    return axis == Axis.horizontal ? Offset(signed, 0) : Offset(0, signed);
  }

  @override
  Widget build(BuildContext context) {
    var content = child;
    if (clips) {
      content = ClipRect(
        child: Transform.translate(
          offset: _along(placement.contentShift),
          child: content,
        ),
      );
    }
    return Offstage(
      offstage: !shows,
      child: TickerMode(
        enabled: shows,
        child: IgnorePointer(
          ignoring: !interactive,
          child: Transform(
            alignment: Alignment.center,
            transform: Matrix4.translationValues(
              _along(placement.offset).dx,
              _along(placement.offset).dy,
              0,
            )..scaleByDouble(placement.scale, placement.scale, 1, 1),
            child: Opacity(
              opacity: placement.opacity.clamp(0.0, 1.0),
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}
