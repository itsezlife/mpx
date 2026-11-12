import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Where an item sits on the surface the viewer opened from: what the open
/// transition starts at and the close transition ends at.
@immutable
final class GalleryOrigin {
  /// Creates an origin.
  const GalleryOrigin({
    required this.rect,
    this.radius = BorderRadius.zero,
    this.clip,
    this.frame,
  });

  /// The item's picture on the surface, in global coordinates.
  final Rect rect;

  /// The corners of the picture there.
  final BorderRadius radius;

  /// The part of the surface the picture shows through (a list's visible
  /// area), in global coordinates; null when nothing clips it.
  final Rect? clip;

  /// The frame the surface shows now (a bubble's current frame), drawn by
  /// the viewer until its own picture is ready; null for none.
  final ui.Image? frame;
}

/// The viewer's link to the surface it opened from: where each item sits,
/// and what the surface does while the viewer covers it.
///
/// The viewer knows nothing about the surface beyond this: no list, no
/// message, no scroll controller.
abstract interface class OriginBridge {
  /// The origin of [index], or null when the item has none on screen (it
  /// scrolled away, it was never in the list). Without one the viewer closes
  /// by sliding off instead of morphing back.
  GalleryOrigin? originOf(int index);

  /// Brings [index]'s origin on screen before the viewer closes on it, when
  /// that is another item than the one it opened from: the surface scrolls to
  /// it. Completes when the origin can be read.
  Future<void> reveal(int index);

  /// Hides or shows [index]'s picture on the surface: hidden while the
  /// viewer's copy stands over it, so the two are never seen at once.
  void setHidden(int index, {required bool hidden});
}
