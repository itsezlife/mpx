import 'package:flutter/foundation.dart';

/// Which pages a gallery pager keeps built while they do not show.
///
/// A kept page keeps its state (zoom, players, loaded content) offstage,
/// out of hit testing and semantics, with its tickers muted; a page that is
/// not kept is disposed and built anew when it shows again. The pages that
/// show are always built.
sealed class GalleryKeepAlive {
  const GalleryKeepAlive._();

  /// Every page once built stays built.
  const factory GalleryKeepAlive.all() = GalleryKeepAlive$All;

  /// Only the pages that show are built.
  const factory GalleryKeepAlive.none() = GalleryKeepAlive$None;

  /// Pages within [pages] of the page the pager rests on stay built once
  /// built.
  const factory GalleryKeepAlive.around(int pages) = GalleryKeepAlive$Around;

  /// Whether a built page [distance] pages from the page the pager rests
  /// on stays built.
  bool keeps(int distance);
}

/// [GalleryKeepAlive.all].
@immutable
final class GalleryKeepAlive$All extends GalleryKeepAlive {
  /// Keeps every page.
  const GalleryKeepAlive$All() : super._();

  @override
  bool keeps(int distance) => true;

  @override
  bool operator ==(Object other) => other is GalleryKeepAlive$All;

  @override
  int get hashCode => (GalleryKeepAlive$All).hashCode;
}

/// [GalleryKeepAlive.none].
@immutable
final class GalleryKeepAlive$None extends GalleryKeepAlive {
  /// Keeps no page that does not show.
  const GalleryKeepAlive$None() : super._();

  @override
  bool keeps(int distance) => false;

  @override
  bool operator ==(Object other) => other is GalleryKeepAlive$None;

  @override
  int get hashCode => (GalleryKeepAlive$None).hashCode;
}

/// [GalleryKeepAlive.around].
@immutable
final class GalleryKeepAlive$Around extends GalleryKeepAlive {
  /// Keeps the pages within [pages].
  const GalleryKeepAlive$Around(this.pages)
    : assert(pages >= 0, 'a distance is never negative'),
      super._();

  /// How far from the page the pager rests on a page stays built.
  final int pages;

  @override
  bool keeps(int distance) => distance.abs() <= pages;

  @override
  bool operator ==(Object other) =>
      other is GalleryKeepAlive$Around && other.pages == pages;

  @override
  int get hashCode => pages.hashCode;
}
