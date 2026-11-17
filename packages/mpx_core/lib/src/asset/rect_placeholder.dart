import 'dart:ui';

import 'package:mpx_core/src/asset/asset_paintable.dart';
import 'package:mpx_core/src/asset/atlas_sprite.dart';

/// A tinted fill a host chooses as the stand-in of media that has nothing
/// to show yet: the whole rectangle in the context's tint.
///
/// No shape is drawn: a corner radius belongs to the surface, which clips
/// what a binding paints to `AssetProfile.cornerRadius`. Without a tint it
/// paints nothing; it has no colour of its own, so media never waits behind
/// a box the host did not ask for. Synchronous, shared, never disposed; no
/// sprite and no animation.
final class RectPlaceholder extends AssetPaintable {
  /// Creates the placeholder.
  const RectPlaceholder();

  // Painting is single-threaded and the paint is set fully on every call.
  static final Paint _paint = Paint();

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
    final base = context.tint;
    if (rect.isEmpty || base == null) return;
    _paint.color = base.withValues(alpha: base.a * context.opacity);
    canvas.drawRect(rect, _paint);
  }

  @override
  void dispose() {}
}
