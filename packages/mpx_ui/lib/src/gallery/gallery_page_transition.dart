import 'package:flutter/foundation.dart';

/// Where a page of a gallery pager is drawn for a pager position: its
/// offset along the axis, its scale and opacity, and whether it is drawn
/// under the pages that are not.
@immutable
final class GalleryPagePlacement {
  /// Creates a placement.
  const GalleryPagePlacement({
    required this.offset,
    this.scale = 1,
    this.opacity = 1,
    this.under = false,
    this.contentShift = 0,
  });

  /// The page's offset along the axis from where it rests, in logical
  /// pixels, positive toward the next page's side.
  final double offset;

  /// The page's scale around its centre.
  final double scale;

  /// The page's opacity.
  final double opacity;

  /// Whether the page is drawn under the others.
  final bool under;

  /// How far the page's content moves inside its clip, along the axis:
  /// parallax.
  final double contentShift;

  /// Whether the page shows at all.
  bool get shows => opacity > 0 && scale > 0;

  @override
  bool operator ==(Object other) =>
      other is GalleryPagePlacement &&
      other.offset == offset &&
      other.scale == scale &&
      other.opacity == opacity &&
      other.under == under &&
      other.contentShift == contentShift;

  @override
  int get hashCode => Object.hash(offset, scale, opacity, under, contentShift);

  @override
  String toString() =>
      'GalleryPagePlacement(offset: $offset, scale: $scale, '
      'opacity: $opacity, under: $under, contentShift: $contentShift)';
}

/// How a gallery pager draws its pages as the position moves between them.
sealed class GalleryPageTransition {
  const GalleryPageTransition._();

  /// The pages side by side, the pager's gap apart, moving with the
  /// position; each page's content lags its page by [parallax] of the way
  /// inside the page's clip.
  const factory GalleryPageTransition.strip({double parallax}) =
      GalleryPageTransition$Strip;

  /// The page on the previous side slides over the one on the next side,
  /// which stays in place under it, shrinking to [minScale] and fading as
  /// it is covered.
  const factory GalleryPageTransition.stack({double minScale}) =
      GalleryPageTransition$Stack;

  /// Only the page nearest the position shows, in place: pages switch at
  /// once.
  const factory GalleryPageTransition.instant() = GalleryPageTransition$Instant;

  /// Where a page [distance] pages from the position (positive: on the next
  /// side) is drawn, with pages [stride] apart (the page's extent plus the
  /// gap). [edge] tells a position past the first or the last page, where
  /// the edge page follows the drag alone.
  GalleryPagePlacement place(
    double distance,
    double stride, {
    bool edge = false,
  });
}

/// [GalleryPageTransition.strip].
@immutable
final class GalleryPageTransition$Strip extends GalleryPageTransition {
  /// A strip with [parallax].
  const GalleryPageTransition$Strip({this.parallax = 0}) : super._();

  /// The share of its page's movement a page's content lags by.
  final double parallax;

  @override
  GalleryPagePlacement place(
    double distance,
    double stride, {
    bool edge = false,
  }) {
    final offset = distance * stride;
    return GalleryPagePlacement(
      offset: offset,
      opacity: distance.abs() < 1 ? 1 : 0,
      contentShift: edge ? 0 : -offset * parallax,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GalleryPageTransition$Strip && other.parallax == parallax;

  @override
  int get hashCode => parallax.hashCode;
}

/// [GalleryPageTransition.stack].
@immutable
final class GalleryPageTransition$Stack extends GalleryPageTransition {
  /// A stack whose covered page shrinks to [minScale].
  const GalleryPageTransition$Stack({this.minScale = 0.7}) : super._();

  /// The scale of the page under at the moment it is fully covered.
  final double minScale;

  @override
  GalleryPagePlacement place(
    double distance,
    double stride, {
    bool edge = false,
  }) {
    if (edge || distance <= 0) {
      return GalleryPagePlacement(
        offset: distance * stride,
        opacity: distance.abs() < 1 ? 1 : 0,
      );
    }
    final covered = distance.clamp(0.0, 1.0);
    return GalleryPagePlacement(
      offset: 0,
      scale: minScale + (1 - minScale) * (1 - covered),
      opacity: 1 - covered,
      under: true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GalleryPageTransition$Stack && other.minScale == minScale;

  @override
  int get hashCode => minScale.hashCode;
}

/// [GalleryPageTransition.instant].
@immutable
final class GalleryPageTransition$Instant extends GalleryPageTransition {
  /// Pages switch at once.
  const GalleryPageTransition$Instant() : super._();

  @override
  GalleryPagePlacement place(
    double distance,
    double stride, {
    bool edge = false,
  }) => GalleryPagePlacement(
    offset: 0,
    opacity: distance.abs() < 0.5 || (distance.abs() == 0.5 && distance < 0)
        ? 1
        : 0,
  );

  @override
  bool operator ==(Object other) => other is GalleryPageTransition$Instant;

  @override
  int get hashCode => (GalleryPageTransition$Instant).hashCode;
}
