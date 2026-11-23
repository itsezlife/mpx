import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// The viewer's caption: a text that starts as tall as [collapsedHeight] (or
/// as its text, when that is shorter) and that a drag up grows over the
/// picture, then scrolls, with its edges fading while there is more text
/// beyond them.
///
/// It is bottom-anchored in the room it is given and never takes more than
/// that room. A drag down goes back the same way: the text scrolls to its
/// start, then the box shrinks to its first size. Only the box takes touches:
/// the picture above it is the picture's.
class ViewerCaptionSheet extends StatefulWidget {
  /// Creates a sheet of [child] on [fill].
  const ViewerCaptionSheet({
    required this.child,
    required this.collapsedHeight,
    required this.fill,
    required this.padding,
    this.fadeLength = 12,
    this.onInteraction,
    this.boxKey,
    super.key,
  });

  /// The text.
  final Widget child;

  /// The height the box starts at, padding included.
  final double collapsedHeight;

  /// The colour behind the text.
  final Color fill;

  /// The room around the text.
  final EdgeInsets padding;

  /// How far a fading edge reaches into the text.
  final double fadeLength;

  /// The key of the box the text sits on: the sheet itself fills the room it
  /// grows in.
  final Key? boxKey;

  /// Told of every touch, so the viewer's auto-hide starts again.
  final VoidCallback? onInteraction;

  @override
  State<ViewerCaptionSheet> createState() => _ViewerCaptionSheetState();
}

class _ViewerCaptionSheetState extends State<ViewerCaptionSheet> {
  final ScrollController _scroll = ScrollController();
  // How tall the box is allowed to be now: its first height, then what the
  // drag has grown it to.
  double? _extent;
  double _room = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_repaint);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _repaint() {
    if (mounted) setState(() {});
  }

  double get _min => math.min(widget.collapsedHeight, _room);

  double get _limit => (_extent ?? _min).clamp(_min, _room);

  // A drag by [delta] (negative is up): up grows the box first, then scrolls
  // the text; down scrolls the text back first, then shrinks the box.
  void _drag(double delta) {
    widget.onInteraction?.call();
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    var rest = -delta;
    var extent = _limit;
    if (rest > 0) {
      // The box only grows while there is text it does not show.
      final hidden = position.maxScrollExtent - position.pixels;
      final grow = math.min(
        math.min(rest, _room - extent),
        math.max(hidden, 0),
      );
      extent += grow;
      rest -= grow;
      if (rest > 0) {
        position.jumpTo(
          (position.pixels + rest).clamp(0.0, position.maxScrollExtent),
        );
      }
    } else if (rest < 0) {
      final scrolled = math.min(-rest, position.pixels);
      if (scrolled > 0) position.jumpTo(position.pixels - scrolled);
      rest += scrolled;
      if (rest < 0) extent = math.max(_min, extent + rest);
    }
    if (extent != _extent) setState(() => _extent = extent);
  }

  void _end(double velocity) {
    if (!_scroll.hasClients) return;
    // A fling carries the text on, when the box has all the room it can.
    if (_limit >= _room) {
      if (_scroll.position
          case final ScrollPositionWithSingleContext position) {
        position.goBallistic(-velocity);
      }
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _room = constraints.maxHeight.isFinite
          ? constraints.maxHeight
          : widget.collapsedHeight;
      final fade = widget.fadeLength;
      final position = _scroll.hasClients ? _scroll.position : null;
      final top = position != null && position.pixels > 0.5;
      final bottom =
          position != null && position.pixels < position.maxScrollExtent - 0.5;
      return Align(
        alignment: Alignment.bottomCenter,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragUpdate: (details) => _drag(details.delta.dy),
          onVerticalDragEnd: (details) => _end(details.primaryVelocity ?? 0),
          onTapDown: (_) => widget.onInteraction?.call(),
          child: ColoredBox(
            key: widget.boxKey,
            color: widget.fill,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: _limit),
              child: ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (bounds) {
                  final reach = math.min(fade / bounds.height, 0.5);
                  final from = top ? reach : 0.0;
                  final to = bottom ? 1 - reach : 1.0;
                  return LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      if (top) const Color(0x00FFFFFF),
                      const Color(0xFFFFFFFF),
                      const Color(0xFFFFFFFF),
                      if (bottom) const Color(0x00FFFFFF),
                    ],
                    stops: [if (top) 0.0, from, to, if (bottom) 1.0],
                  ).createShader(bounds);
                },
                child: SingleChildScrollView(
                  controller: _scroll,
                  physics: const _DragOnlyPhysics(),
                  padding: widget.padding,
                  child: SizedBox(width: double.infinity, child: widget.child),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

// A scroll view the sheet drives itself: it takes no touches of its own and
// still runs a fling it is told to.
class _DragOnlyPhysics extends ClampingScrollPhysics {
  const _DragOnlyPhysics({super.parent});

  @override
  _DragOnlyPhysics applyTo(ScrollPhysics? ancestor) =>
      _DragOnlyPhysics(parent: buildParent(ancestor));

  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) => false;
}
