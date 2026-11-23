import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// The viewer's caption, as the reference's is: a scroll view over all the
/// room it is given, whose text starts as low as [collapsedHeight] (or as its
/// own height, when that is less) and which a drag up takes over the picture,
/// the box behind the text growing with it.
///
/// - The text scrolls like any scroll view, and gives under a pull past an end
///   (`BouncingScrollPhysics`, whose spring is the reference's: stiffness
///   100, no bounce of its own). Text that all shows has no range to scroll
///   and gives nothing.
/// - The edges fade while there is more text beyond them.
/// - Only the box and its text take touches; the room above them is the
///   picture's.
class ViewerCaptionSheet extends StatefulWidget {
  /// Creates a sheet of [child] on [fill].
  const ViewerCaptionSheet({
    required this.child,
    required this.collapsedHeight,
    required this.fill,
    required this.padding,
    this.fadeLength = 12,
    this.onInteraction,
    super.key,
  });

  /// The text.
  final Widget child;

  /// The height the text starts at, padding included.
  final double collapsedHeight;

  /// The colour behind the text.
  final Color fill;

  /// The room around the text.
  final EdgeInsets padding;

  /// How far a fading edge reaches into the text.
  final double fadeLength;

  /// Told of every touch, so the viewer's auto-hide starts again.
  final VoidCallback? onInteraction;

  @override
  State<ViewerCaptionSheet> createState() => _ViewerCaptionSheetState();
}

class _ViewerCaptionSheetState extends State<ViewerCaptionSheet> {
  final ScrollController _scroll = ScrollController();
  final _CaptionGeometry _geometry = _CaptionGeometry();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  // Where the text starts in the room now: its margin, less what is scrolled.
  // A pull past an end moves it too, as it moves the text.
  double _topNow() =>
      _geometry.margin - (_scroll.hasClients ? _scroll.offset : 0);

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final room = constraints.maxHeight.isFinite
          ? constraints.maxHeight
          : widget.collapsedHeight;
      return Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => widget.onInteraction?.call(),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // The box behind the text goes up with it: painted from where the
            // text starts as the frame is drawn, after the layout that says.
            CustomPaint(
              painter: _BoxPainter(
                geometry: _geometry,
                scroll: _scroll,
                color: widget.fill,
              ),
            ),
            _PassThrough(
              top: _topNow,
              child: ListenableBuilder(
                listenable: _scroll,
                builder: (context, _) => ShaderMask(
                  blendMode: BlendMode.dstIn,
                  // A new callback each time: the fade follows the scroll.
                  // ignore: unnecessary_lambdas
                  shaderCallback: (bounds) => _fade(bounds),
                  child: SingleChildScrollView(
                    controller: _scroll,
                    physics: const BouncingScrollPhysics(),
                    child: _CaptionBody(
                      geometry: _geometry,
                      room: room,
                      collapsedHeight: widget.collapsedHeight,
                      child: Padding(
                        padding: widget.padding,
                        child: SizedBox(
                          width: double.infinity,
                          child: widget.child,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );

  // Opaque but at the box's edges, where there is more text beyond them.
  Shader _fade(Rect bounds) {
    final position = _scroll.hasClients ? _scroll.position : null;
    final scrolled = position != null && position.pixels > 0.5;
    final more =
        position != null && position.pixels < position.maxScrollExtent - 0.5;
    // The top edge is the box's, not the room's: the text is under it.
    final height = bounds.height <= 0 ? 1.0 : bounds.height;
    final from = (_topNow() / height).clamp(0.0, 1.0);
    final reach = widget.fadeLength / height;
    final solidFrom = scrolled ? math.min<double>(from + reach, 1) : from;
    final solidTo = more ? math.max<double>(1 - reach, 0) : 1.0;
    return LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        if (scrolled) const Color(0x00FFFFFF),
        const Color(0xFFFFFFFF),
        const Color(0xFFFFFFFF),
        if (more) const Color(0x00FFFFFF),
      ],
      stops: [if (scrolled) from, solidFrom, solidTo, if (more) 1],
    ).createShader(bounds);
  }
}

// The box behind the text: from where the text starts to the foot of the
// room.
class _BoxPainter extends CustomPainter {
  _BoxPainter({
    required this.geometry,
    required this.scroll,
    required this.color,
  }) : super(repaint: scroll);

  final _CaptionGeometry geometry;
  final ScrollController scroll;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final top = geometry.margin - (scroll.hasClients ? scroll.offset : 0);
    canvas.drawRect(
      Rect.fromLTRB(0, math.max(0, top), size.width, size.height),
      Paint()..color = color,
    );
  }

  // It only paints: the touches are the scroll view's, and the picture's.
  @override
  bool? hitTest(Offset position) => false;

  @override
  bool shouldRepaint(_BoxPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.geometry != geometry;
}

// What the body's layout tells the sheet: where its text starts.
final class _CaptionGeometry {
  double margin = 0;
}

// The scroll view's content: the room's height at least, the text at its
// bottom, as far down as its first height says. Its margin is what the box
// behind the text and the touches above it follow.
class _CaptionBody extends SingleChildRenderObjectWidget {
  const _CaptionBody({
    required this.geometry,
    required this.room,
    required this.collapsedHeight,
    required super.child,
  });

  final _CaptionGeometry geometry;
  final double room;
  final double collapsedHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderCaptionBody(geometry, room, collapsedHeight);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderCaptionBody renderObject,
  ) {
    renderObject
      ..geometry = geometry
      ..room = room
      ..collapsedHeight = collapsedHeight;
  }
}

class _RenderCaptionBody extends RenderBox
    with RenderObjectWithChildMixin<RenderBox> {
  _RenderCaptionBody(this._geometry, this._room, this._collapsedHeight);

  _CaptionGeometry _geometry;
  double _room;
  double _collapsedHeight;
  double _margin = 0;

  set geometry(_CaptionGeometry value) => _geometry = value;

  set room(double value) {
    if (value == _room) return;
    _room = value;
    markNeedsLayout();
  }

  set collapsedHeight(double value) {
    if (value == _collapsedHeight) return;
    _collapsedHeight = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderObject child) {
    if (child.parentData is! BoxParentData) child.parentData = BoxParentData();
  }

  @override
  void performLayout() {
    final child = this.child!;
    child.layout(
      BoxConstraints(
        minWidth: constraints.maxWidth,
        maxWidth: constraints.maxWidth,
      ),
      parentUsesSize: true,
    );
    final text = child.size.height;
    _margin = math.max(0, _room - math.min(text, _collapsedHeight));
    _geometry.margin = _margin;
    (child.parentData! as BoxParentData).offset = Offset(0, _margin);
    size = constraints.constrain(Size(constraints.maxWidth, _margin + text));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    context.paintChild(child!, offset + Offset(0, _margin));
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      result.addWithPaintOffset(
        offset: Offset(0, _margin),
        position: position,
        hitTest: (result, transformed) =>
            child!.hitTest(result, position: transformed),
      );
}

// Passes every touch above the text to what is behind: the scroll view
// claims its whole viewport, which here is all the room above the box too.
class _PassThrough extends SingleChildRenderObjectWidget {
  const _PassThrough({required this.top, required super.child});

  /// Where the text starts in the viewport now.
  final double Function() top;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPassThrough(top);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderPassThrough renderObject,
  ) => renderObject.top = top;
}

class _RenderPassThrough extends RenderProxyBox {
  _RenderPassThrough(this.top);

  double Function() top;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (position.dy < top()) return false;
    return super.hitTest(result, position: position);
  }
}
