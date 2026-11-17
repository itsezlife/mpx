import 'dart:ui';

import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';
import 'package:mpx_core/src/asset/asset_paintable.dart';
import 'package:mpx_core/src/asset/atlas_sprite.dart';

/// A sweep of light across an outline preview, repeating while it shows: a
/// highlight crosses the outline over [sweep] along [curve], then rests for
/// [wait] before the next pass.
@immutable
final class OutlineShimmer {
  /// Creates a shimmer.
  const OutlineShimmer({
    required this.sweep,
    this.curve = Curves.linear,
    this.wait = Duration.zero,
  });

  /// How long the highlight takes to cross.
  final Duration sweep;

  /// How the highlight moves across.
  final Curve curve;

  /// The rest between two passes.
  final Duration wait;

  /// The length of one pass and its rest.
  Duration get period => sweep + wait;

  /// Where the highlight is at [time] of the clock, 0 (entering on the
  /// leading side) to 1 (leaving on the trailing side), or null while it
  /// rests.
  double? phaseAt(Duration time) {
    final period = this.period.inMicroseconds;
    if (period <= 0) return null;
    final into = time.inMicroseconds % period;
    if (into >= sweep.inMicroseconds) return null;
    return curve.transform(into / sweep.inMicroseconds);
  }

  @override
  bool operator ==(Object other) =>
      other is OutlineShimmer &&
      other.sweep == sweep &&
      other.curve == curve &&
      other.wait == wait;

  @override
  int get hashCode => Object.hash(sweep, curve, wait);

  @override
  String toString() => 'OutlineShimmer($sweep, $curve, wait: $wait)';
}

/// How a surface wants an outline preview drawn: its [fill], and where the
/// shimmer's highlight is ([highlight], 0 to 1 across, or null for none).
///
/// The surface resolves both from its loading style and its clock, so the
/// outline keeps no time of its own and costs nothing while nobody shows it.
@immutable
final class OutlineLook {
  /// Creates a look.
  const OutlineLook({required this.fill, this.highlight});

  /// The colour the outline is filled with.
  final Color fill;

  /// Where the highlight crosses, 0 (entering) to 1 (leaving), or null.
  final double? highlight;

  @override
  bool operator ==(Object other) =>
      other is OutlineLook &&
      other.fill == fill &&
      other.highlight == highlight;

  @override
  int get hashCode => Object.hash(fill, highlight);

  @override
  String toString() => 'OutlineLook($fill, highlight: $highlight)';
}

/// An outline preview: the vector shape of a piece of media (a sticker, an
/// emoji), filled, placed in the box as the profile fits the content.
///
/// Drawn as the surface's [OutlineLook] says (`AssetPaintContext.outline`),
/// else in the context's tint, else in a quiet translucent grey. A still: it
/// is never on the playback clock; a shimmer is the surface's to drive.
final class OutlinePaintable extends AssetPaintable {
  /// Draws [path], laid out in [viewBox].
  OutlinePaintable(this.path, this.viewBox);

  /// The outline, in the coordinates of [viewBox].
  final Path path;

  /// The box [path] is laid out in.
  final Size viewBox;

  static const Color _fallback = Color(0x46000000);

  // The path placed in the last box it was drawn into.
  Rect? _placedIn;
  Path? _placed;

  @override
  Size? get pictureSize => viewBox;

  @override
  AtlasSprite? get sprite => null;

  @override
  bool get isAnimated => false;

  @override
  bool get isHolding => false;

  @override
  bool restart() => false;

  @override
  void paint(Canvas canvas, Rect rect, AssetPaintContext context) {
    if (rect.isEmpty || viewBox.isEmpty || context.opacity <= 0) return;
    final destination = context.fit.place(viewBox, rect).destination;
    final placed = _placedIn == destination ? _placed! : _place(destination);
    final look = context.outline;
    final fill = look?.fill ?? context.tint ?? _fallback;
    canvas.drawPath(
      placed,
      Paint()..color = fill.withValues(alpha: fill.a * context.opacity),
    );
    final highlight = look?.highlight;
    if (highlight == null) return;
    // A band a third of the width wide crosses from before the left edge
    // to past the right one.
    final band = destination.width / 3;
    final centre =
        destination.left - band + highlight * (destination.width + 2 * band);
    final glow = Color.fromRGBO(255, 255, 255, 0.35 * context.opacity);
    final clear = glow.withValues(alpha: 0);
    canvas.drawPath(
      placed,
      Paint()
        ..shader = Gradient.linear(
          Offset(centre - band / 2, 0),
          Offset(centre + band / 2, 0),
          [clear, glow, clear],
          const [0, 0.5, 1],
        ),
    );
  }

  Path _place(Rect destination) {
    final scaleX = destination.width / viewBox.width;
    final scaleY = destination.height / viewBox.height;
    final matrix = Float64List(16)
      ..[0] = scaleX
      ..[5] = scaleY
      ..[10] = 1
      ..[12] = destination.left
      ..[13] = destination.top
      ..[15] = 1;
    _placedIn = destination;
    return _placed = path.transform(matrix);
  }

  @override
  void dispose() {}
}
