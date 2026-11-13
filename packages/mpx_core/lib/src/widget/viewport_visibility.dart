import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

/// Where a box shows through the scrollable viewports around it: its
/// rectangle on screen, the clip of those viewports, how much of it shows
/// and how far it is from view.
///
/// One walk out from the box through every enclosing
/// `RenderAbstractViewport` (lists, grids, slivers, pagers, a host's own),
/// so a box in a horizontal list inside a vertical one is clipped by both.
/// It assumes no axis, extent or viewport type. A box some parent does not
/// paint (a cell kept alive off screen, an offstage page, a zero opacity)
/// is out of every view.
///
/// For a feed slot measuring its visible share, a viewer origin finding its
/// place, or any surface that asks "is this on screen, and where".
@immutable
final class ViewportVisibility {
  const ViewportVisibility._({
    required this.rect,
    required this.clip,
    required this.fraction,
    required this.centreDistance,
    required this.viewportsAway,
  });

  /// Measures [box] now; call it after layout.
  factory ViewportVisibility.of(RenderBox box) {
    if (!box.attached || !box.hasSize || box.size.isEmpty) return unseen;
    final rect = MatrixUtils.transformRect(
      box.getTransformTo(null),
      Offset.zero & box.size,
    );
    Rect? clip;
    Rect? closest;
    RenderObject inner = box;
    var viewport = RenderAbstractViewport.maybeOf(box.parent);
    while (viewport != null) {
      if (!_paintedUpTo(inner, viewport)) return unseen;
      final bounds = MatrixUtils.transformRect(
        viewport.getTransformTo(null),
        viewport.paintBounds,
      );
      closest ??= bounds;
      clip = clip == null ? bounds : clip.intersect(bounds);
      inner = viewport;
      viewport = RenderAbstractViewport.maybeOf(viewport.parent);
    }
    if (!_paintedUpTo(inner, null)) return unseen;
    if (clip == null || closest == null) {
      return ViewportVisibility._(
        rect: rect,
        clip: null,
        fraction: 1,
        centreDistance: 0,
        viewportsAway: 0,
      );
    }
    final shown = rect.intersect(clip);
    final fraction = shown.width <= 0 || shown.height <= 0
        ? 0.0
        : (shown.width * shown.height / (rect.width * rect.height)).clamp(
            0.0,
            1.0,
          );
    return ViewportVisibility._(
      rect: rect,
      clip: clip,
      fraction: fraction,
      centreDistance: (rect.center - closest.center).distance,
      viewportsAway: fraction > 0 ? 0 : _away(rect, closest),
    );
  }

  /// A box that is out of every view: unattached, unsized, empty or not
  /// painted.
  static const ViewportVisibility unseen = ViewportVisibility._(
    rect: Rect.zero,
    clip: null,
    fraction: 0,
    centreDistance: 0,
    viewportsAway: double.infinity,
  );

  /// The box on screen, in global coordinates; [Rect.zero] when [unseen].
  final Rect rect;

  /// The intersection of every enclosing viewport's bounds, in global
  /// coordinates; null when no viewport encloses the box.
  final Rect? clip;

  /// The share of the box's area that shows, 0 to 1. Exact under the scale
  /// and translation a viewport applies.
  final double fraction;

  /// How far the box's centre is from the closest viewport's centre, in
  /// logical pixels; 0 without a viewport. What breaks ties between items
  /// that show alike.
  final double centreDistance;

  /// How far the box is from the closest viewport, in that viewport's
  /// extents along the gap: 0 while any of it shows, 1 a whole viewport
  /// away, infinite when it is not painted at all. A box laid out ahead of
  /// view (in a list's cache extent) has a finite distance.
  final double viewportsAway;

  /// Whether any of the box shows.
  bool get shows => fraction > 0;

  /// Whether all of the box shows.
  bool get showsWhole {
    final clip = this.clip;
    if (!shows) return false;
    return clip == null || clip.intersect(rect) == rect;
  }

  @override
  bool operator ==(Object other) =>
      other is ViewportVisibility &&
      other.rect == rect &&
      other.clip == clip &&
      other.fraction == fraction &&
      other.centreDistance == centreDistance &&
      other.viewportsAway == viewportsAway;

  @override
  int get hashCode =>
      Object.hash(rect, clip, fraction, centreDistance, viewportsAway);

  @override
  String toString() =>
      'ViewportVisibility($rect, clip: $clip, fraction: $fraction, '
      'centreDistance: $centreDistance, viewportsAway: $viewportsAway)';
}

// The gap between [rect] and [bounds] along each axis, in [bounds]' extent
// along it; the larger of the two.
double _away(Rect rect, Rect bounds) {
  final dy = math.max(bounds.top - rect.bottom, rect.top - bounds.bottom);
  final dx = math.max(bounds.left - rect.right, rect.left - bounds.right);
  return math.max(
    bounds.height > 0 ? math.max(dy, 0) / bounds.height : 0,
    bounds.width > 0 ? math.max(dx, 0) / bounds.width : 0,
  );
}

// Whether every parent from [child] up to [ancestor] (the root when null)
// paints the one below it.
bool _paintedUpTo(RenderObject child, RenderObject? ancestor) {
  var node = child;
  while (!identical(node, ancestor)) {
    final parent = node.parent;
    if (parent == null) return ancestor == null;
    if (!parent.paintsChild(node)) return false;
    node = parent;
  }
  return true;
}
