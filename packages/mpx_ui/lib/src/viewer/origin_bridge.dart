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
    this.position,
  });

  /// The item's picture on the surface, in global coordinates.
  final Rect rect;

  /// The corners of the picture there.
  final BorderRadius radius;

  /// The part of the surface the picture shows through (a list's visible
  /// area), in global coordinates; null when nothing clips it.
  final Rect? clip;

  /// Where the surface's playback of the item is (a bubble's silent loop):
  /// a video opens on the player from there. Null to start from the
  /// beginning.
  final Duration? position;
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

  /// The picture [index]'s origin shows now (a bubble's current frame), or
  /// the one it showed as it was hidden; the viewer draws it until its own
  /// picture is ready. Null when there is none.
  ///
  /// Each call hands out a new handle ([ui.Image.clone]) that the caller
  /// owns and disposes: the bridge may free its own copy at any time (when
  /// the origin shows again), and a picture the caller still paints must not
  /// go with it. [originOf] carries no picture, so reading a place stays
  /// cheap.
  ui.Image? frameOf(int index);

  /// Brings [index]'s origin on screen before the viewer closes on it, when
  /// that is another item than the one it opened from: the surface scrolls to
  /// it. Completes when the origin can be read.
  Future<void> reveal(int index);

  /// Hides or shows [index]'s picture on the surface: hidden while the
  /// viewer's copy stands over it, so the two are never seen at once.
  void setHidden(int index, {required bool hidden});

  /// Tells the surface where the player of [index] stands as the viewer
  /// closes on it, so the bubble's loop continues from there.
  void handBack(int index, Duration position);
}
