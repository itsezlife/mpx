import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_ui/src/viewer/gallery_source.dart';
import 'package:mpx_ui/src/viewer/viewer_policy.dart';

/// One thumbnail of the strip, where it stands.
@immutable
class ViewerStripItem {
  /// Creates an item.
  const ViewerStripItem({
    required this.index,
    required this.left,
    required this.width,
    required this.inset,
  });

  /// Which item of the gallery.
  final int index;

  /// Where its slot starts, from the strip's left edge.
  final double left;

  /// How wide its slot is: the picture and a gap on each side.
  final double width;

  /// The gap on each side of the picture in the slot.
  final double inset;

  /// Where the picture starts.
  double get pictureLeft => left + inset;

  /// How wide the picture is.
  double get pictureWidth => width - 2 * inset;
}

/// Where the thumbnails of the strip stand for a focus, as the reference's
/// strip draws them: the thumbnail the focus is on is as wide as its picture
/// at the strip's height (between the base width and [maxWidth]) with a gap
/// on each side, the others are the base width; between two items the two
/// are part way, in proportion, and the row moves to keep the focus in the
/// middle. No easing: it is the focus that moves, and a finger or an
/// animation moves it.
abstract final class ViewerStripLayout {
  /// The items on the screen for [focus] (a fractional index) in a strip
  /// [viewport] wide.
  ///
  /// [pictureWidthOf] gives the width an item's picture would have at the
  /// strip's height; [padding] is the gap on each side of a grown item.
  static List<ViewerStripItem> of({
    required double viewport,
    required int count,
    required double focus,
    required double baseWidth,
    required double spacing,
    required double padding,
    required double maxWidth,
    required double Function(int index) pictureWidthOf,
  }) {
    if (count <= 0) return const [];
    final held = focus.clamp(0, count - 1).toDouble();
    final low = held.floor();
    return between(
      viewport: viewport,
      count: count,
      from: low,
      to: math.min(count - 1, low + 1),
      progress: held - low,
      baseWidth: baseWidth,
      spacing: spacing,
      padding: padding,
      maxWidth: maxWidth,
      pictureWidthOf: pictureWidthOf,
    );
  }

  /// The items on the screen as the focus goes from the item [from] to the
  /// item [to], [progress] of the way (0 to 1): [from] shrinks to the base as
  /// [to] grows, and the row moves to keep the point between them in the
  /// middle. The two are neighbours for a finger on the pager, and anywhere
  /// for a jump: the reference grows the target and shrinks the one it leaves,
  /// and no item between.
  static List<ViewerStripItem> between({
    required double viewport,
    required int count,
    required int from,
    required int to,
    required double progress,
    required double baseWidth,
    required double spacing,
    required double padding,
    required double maxWidth,
    required double Function(int index) pictureWidthOf,
  }) {
    if (count <= 0) return const [];
    final start = from.clamp(0, count - 1);
    final end = to.clamp(0, count - 1);
    final t = progress.clamp(0, 1).toDouble();
    // Only what the strip can show is laid out around the two ends; between
    // them the row is added up by the base width.
    final reach = (viewport / (baseWidth + spacing)).ceil() + 3;
    final lowest = math.max(0, math.min(start, end) - reach);
    final highest = math.min(count - 1, math.max(start, end) + reach);

    double enlarged(int index) {
      final width = pictureWidthOf(index);
      return math.min(maxWidth, math.max(baseWidth, width));
    }

    double growth(int i) {
      if (start == end) return i == start ? 1 : 0;
      if (i == start) return 1 - t;
      if (i == end) return t;
      return 0;
    }

    final widths = <int, double>{};
    final insets = <int, double>{};
    final lefts = <int, double>{};
    var x = 0.0;
    for (var i = lowest; i <= highest; i++) {
      final g = growth(i);
      widths[i] = baseWidth + (enlarged(i) - baseWidth) * g + 2 * padding * g;
      insets[i] = padding * g;
      lefts[i] = x;
      x += widths[i]! + spacing;
    }
    double centre(int i) => lefts[i]! + widths[i]! / 2;
    final focusCentre = centre(start) + (centre(end) - centre(start)) * t;
    final shift = viewport / 2 - focusCentre;

    return [
      for (var i = lowest; i <= highest; i++)
        if (lefts[i]! + shift + widths[i]! > -baseWidth &&
            lefts[i]! + shift < viewport + baseWidth)
          ViewerStripItem(
            index: i,
            left: lefts[i]! + shift,
            width: widths[i]!,
            inset: insets[i]!,
          ),
    ];
  }
}

/// The strip of the gallery's thumbnails at the bottom of the viewer, as the
/// reference draws and moves it.
///
/// - The item on show is wider, by its proportion, and the strip keeps it in
///   the middle ([ViewerStripLayout]).
/// - It follows the pager as a finger drags it ([position]): the item on show
///   shrinks as the next grows, the row moves with the finger.
/// - A jump of the item without a drag (a tap on a thumbnail, a key) moves the
///   focus on its own: 200 ms, 100 ms when it is the next item, with the
///   reference's ease-out curve.
/// - A tap on a thumbnail shows its item; a drag along the strip scrubs
///   through the items, which change as the finger crosses them, and lets the
///   focus settle on the one it stops at.
class ViewerThumbnailStrip extends StatefulWidget {
  /// Creates a strip over [source], on [index].
  const ViewerThumbnailStrip({
    required this.source,
    required this.index,
    required this.metrics,
    required this.fill,
    required this.placeholder,
    required this.onSelect,
    this.position,
    this.scope,
    super.key,
  });

  /// The gallery.
  final GallerySource source;

  /// The item on show.
  final int index;

  /// The pager's continuous page, to follow a drag by.
  final ValueListenable<double>? position;

  /// Sizes and gaps.
  final ViewerChromeMetrics metrics;

  /// The strip's fill.
  final Color fill;

  /// What shows where a thumbnail is not here yet.
  final Color placeholder;

  /// A thumbnail was tapped, or the strip was scrubbed to [index].
  final ValueChanged<int> onSelect;

  /// The cache the thumbnails attach to.
  final AssetCacheScope? scope;

  @override
  State<ViewerThumbnailStrip> createState() => _ViewerThumbnailStripState();
}

class _ViewerThumbnailStripState extends State<ViewerThumbnailStrip>
    with TickerProviderStateMixin {
  // The reference's ease-out: cubic-bezier(0, 0, .58, 1).
  static const Curve _easeOut = Cubic(0, 0, 0.58, 1);

  // A strip of at least this many items is carried on by a fling, as the
  // reference's is; a shorter one is only dragged.
  static const int _flingFrom = 10;

  late final AnimationController _move;
  // The fling's own motion: the focus in pixels of the strip.
  late final AnimationController _fling;
  // The strip's own appearance, apart from the chrome's: 200 ms, linear.
  late final AnimationController _appear;
  // Where the focus is: a fractional item, or, in a jump, the item it comes
  // from, the item it goes to and how far.
  double _focus = 0;
  int _jumpFrom = 0;
  int _jumpTo = 0;
  bool _jumping = false;
  // A finger is on the strip, moving the focus itself.
  bool _scrubbing = false;
  double _lastPosition = 0;

  @override
  void initState() {
    super.initState();
    _focus = widget.index.toDouble();
    _lastPosition = widget.position?.value ?? widget.index.toDouble();
    _move = AnimationController(vsync: this)..addListener(_onMove);
    _fling = AnimationController.unbounded(vsync: this)
      ..addListener(_onFling)
      ..addStatusListener(_onFlingStatus);
    _appear = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    )..forward();
    widget.position?.addListener(_onPosition);
  }

  @override
  void didUpdateWidget(ViewerThumbnailStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.position, widget.position)) {
      oldWidget.position?.removeListener(_onPosition);
      widget.position?.addListener(_onPosition);
    }
    if (widget.position == null && oldWidget.index != widget.index) {
      _animateTo(widget.index);
    }
  }

  @override
  void dispose() {
    widget.position?.removeListener(_onPosition);
    _move.dispose();
    _fling.dispose();
    _appear.dispose();
    super.dispose();
  }

  void _onMove() {
    if (_move.isCompleted && _jumping) {
      _jumping = false;
      _focus = _jumpTo.toDouble();
    }
    setState(() {});
  }

  // The pager moved: a continuous move (a drag, a settle) is followed as it
  // is; a jump (more than a page at once) is a change of item of its own.
  void _onPosition() {
    if (_scrubbing) return;
    final position = widget.position!.value;
    final jump = (position - _lastPosition).abs();
    _lastPosition = position;
    if (jump > 1.01) {
      _animateTo(position.round());
      return;
    }
    if (_jumping) {
      // The pager caught up with a move under way: it leads.
      _jumping = false;
      _move.stop();
    }
    setState(() => _focus = position);
  }

  // A change of item with no finger: the focus goes from the item it is on to
  // the new one in 200 ms (100 ms for the next one), easing out.
  void _animateTo(int target) {
    final from = _focus.round();
    if (target == from && !_jumping) return;
    _jumping = true;
    _jumpFrom = _jumping && _move.isAnimating ? _jumpTo : from;
    _jumpTo = target;
    _focus = target.toDouble();
    _move
      ..duration = Duration(
        milliseconds: (target - _jumpFrom).abs() <= 1 ? 100 : 200,
      )
      ..forward(from: 0);
  }

  // --- Scrubbing --------------------------------------------------------

  double get _pitch =>
      widget.metrics.thumbSize.width + widget.metrics.thumbSpacing;

  void _scrubStart(DragStartDetails details) {
    _move.stop();
    _fling.stop();
    _scrubbing = true;
  }

  void _scrubUpdate(DragUpdateDetails details) {
    final count = widget.source.count;
    final focus = (_focus - details.delta.dx / _pitch)
        .clamp(0, count - 1)
        .toDouble();
    final was = _focus.round();
    setState(() => _focus = focus);
    if (focus.round() != was) widget.onSelect(focus.round());
  }

  void _scrubEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final count = widget.source.count;
    if (count >= _flingFrom && velocity.abs() > 50) {
      // Carried on: the focus in pixels of the strip goes by the platform's
      // own deceleration, against the ends.
      final extent = (count - 1) * _pitch;
      _jumping = false;
      _fling.value = _focus * _pitch;
      _fling.animateWith(
        ClampingScrollSimulation(
          position: _focus * _pitch,
          velocity: -velocity,
        ),
      );
      _flingBounds = extent;
      return;
    }
    _settle();
  }

  double _flingBounds = 0;

  void _onFling() {
    final focus = (_fling.value / _pitch).clamp(0, widget.source.count - 1);
    final was = _focus.round();
    setState(() => _focus = focus.toDouble());
    if (_focus.round() != was) widget.onSelect(_focus.round());
    // Against an end it stops there.
    if (_fling.value <= 0 || _fling.value >= _flingBounds) {
      _fling.stop();
      if (_scrubbing) _settle();
    }
  }

  void _onFlingStatus(AnimationStatus status) {
    if (_scrubbing && status == AnimationStatus.completed) _settle();
  }

  // The focus settles on the item it stopped nearest.
  void _settle() {
    _scrubbing = false;
    _lastPosition = widget.position?.value ?? _focus.roundToDouble();
    final target = _focus.round();
    _jumping = true;
    _jumpFrom = _focus.floor();
    _jumpTo = target;
    _move
      ..duration = const Duration(milliseconds: 200)
      ..forward(from: 0);
  }

  // --- Build ----------------------------------------------------------------

  double _pictureWidthOf(int index) {
    final size = widget.source.itemAt(index)?.size;
    final height = widget.metrics.thumbSize.height;
    if (size == null || size.isEmpty) return height;
    return size.width * (height / size.height);
  }

  @override
  Widget build(BuildContext context) {
    final metrics = widget.metrics;
    final thumb = metrics.thumbSize;
    return AnimatedBuilder(
      animation: _appear,
      builder: (context, child) => Opacity(
        key: const ValueKey('mpx-viewer-strip-fade'),
        opacity: _appear.value,
        child: child,
      ),
      child: SizedBox(
        key: const ValueKey('mpx-viewer-strip'),
        height: metrics.stripHeight,
        child: ColoredBox(
          color: widget.fill,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final items = _jumping
                  ? ViewerStripLayout.between(
                      viewport: constraints.maxWidth,
                      count: widget.source.count,
                      from: _jumpFrom,
                      to: _jumpTo,
                      progress: _easeOut.transform(_move.value),
                      baseWidth: thumb.width,
                      spacing: metrics.thumbSpacing,
                      padding: metrics.currentThumbPadding,
                      maxWidth: metrics.currentThumbMaxWidth,
                      pictureWidthOf: _pictureWidthOf,
                    )
                  : ViewerStripLayout.of(
                      viewport: constraints.maxWidth,
                      count: widget.source.count,
                      focus: _focus,
                      baseWidth: thumb.width,
                      spacing: metrics.thumbSpacing,
                      padding: metrics.currentThumbPadding,
                      maxWidth: metrics.currentThumbMaxWidth,
                      pictureWidthOf: _pictureWidthOf,
                    );
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragStart: _scrubStart,
                onHorizontalDragUpdate: _scrubUpdate,
                onHorizontalDragEnd: _scrubEnd,
                onHorizontalDragCancel: () => _scrubEnd(DragEndDetails()),
                child: Stack(
                  clipBehavior: Clip.hardEdge,
                  children: [
                    for (final item in items)
                      Positioned(
                        key: ValueKey(('mpx-viewer-thumb', item.index)),
                        left: item.pictureLeft,
                        top: metrics.thumbTop,
                        width: item.pictureWidth,
                        height: thumb.height,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _tap(item.index),
                          child: _Thumb(
                            item: widget.source.itemAt(item.index),
                            radius: metrics.thumbRadius,
                            placeholder: widget.placeholder,
                            scope: widget.scope,
                            // The size the picture is asked for does not change
                            // as the thumbnail grows and shrinks: one decode.
                            decode: Size(
                              metrics.currentThumbMaxWidth,
                              thumb.height,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  void _tap(int index) {
    // A touch stops a fling, as the reference's does.
    if (_scrubbing) {
      _fling.stop();
      _scrubbing = false;
    }
    if (index == widget.index) return;
    widget.onSelect(index);
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({
    required this.item,
    required this.radius,
    required this.placeholder,
    required this.scope,
    required this.decode,
  });

  final GalleryItem? item;
  final double radius;
  final Color placeholder;
  final AssetCacheScope? scope;
  final Size decode;

  @override
  Widget build(BuildContext context) {
    final item = this.item;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: item == null
          ? ColoredBox(color: placeholder)
          : AssetView(
              content: item.key,
              scope: scope,
              preset: AssetPresets.media(
                size: decode,
                devicePixelRatio:
                    MediaQuery.maybeDevicePixelRatioOf(context) ?? 1,
                profile: const AssetProfile(fit: AssetFit.cover),
              ),
            ),
    );
  }
}
