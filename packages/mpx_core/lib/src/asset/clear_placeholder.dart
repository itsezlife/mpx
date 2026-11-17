import 'dart:ui';

import 'package:mpx_core/src/asset/asset_paintable.dart';
import 'package:mpx_core/src/asset/atlas_sprite.dart';

/// The scope's default stand-in of media that has nothing to show yet: it
/// paints nothing, so the surface behind shows through.
///
/// Media is never drawn as a flat box before its content: the first picture a
/// surface shows is a preview, a thumbnail or the content itself. A surface
/// that wants a fill under its media until then passes its own placeholder
/// (a tinted `RectPlaceholder`).
///
/// Synchronous, shared, never disposed; no sprite and no animation.
final class ClearPlaceholder extends AssetPaintable {
  /// Creates the placeholder.
  const ClearPlaceholder();

  @override
  AtlasSprite? get sprite => null;

  @override
  bool get isAnimated => false;

  @override
  bool get isHolding => false;

  @override
  bool restart() => false;

  @override
  void paint(Canvas canvas, Rect rect, AssetPaintContext context) {}

  @override
  void dispose() {}
}
