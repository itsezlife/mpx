import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:mpx_core/mpx_core.dart';

/// A decoded still, placed in its rectangle as the surface's
/// `AssetPaintContext.fit` says (contain unless it asks to cover): the thumbnail
/// and first-frame stages of a video asset, and what the clip shows until its
/// first frame is drawn from the pool.
///
/// It never animates, so a binding of it costs the clock nothing. The same
/// idea as the stills of mpx_core's image decoder and of `mpx_lottie`, which
/// this package does not depend on.
final class VideoStillPaintable extends AssetPaintable {
  /// Paints [image], which it owns from now on.
  VideoStillPaintable(this._image);

  final ui.Image _image;

  @override
  Size get pictureSize =>
      Size(_image.width.toDouble(), _image.height.toDouble());

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
    final placed = context.fit.place(
      Size(_image.width.toDouble(), _image.height.toDouble()),
      rect,
    );
    canvas.drawImageRect(
      _image,
      placed.source,
      placed.destination,
      Paint()
        ..filterQuality = FilterQuality.medium
        ..color = Color.fromRGBO(0, 0, 0, context.opacity),
    );
  }

  @override
  void dispose() => _image.dispose();
}
