import 'dart:math' as math;
import 'dart:ui';

/// Where the pictures of a post sit in the width it has, as a chat album
/// lays its media out: one picture keeps its proportion within limits, two
/// sit side by side or stacked, three and four put the first (when it is
/// wide, along the top) beside or over the rest.
///
/// Pure arithmetic on aspect ratios (width over height), so the feed can
/// size a decode for a tile before any widget lays it out.
abstract final class AlbumLayout {
  /// The gap between two tiles.
  static const double gap = 2;

  /// The narrowest and widest proportion a lone picture is shown in: a
  /// tall one is cut to 4:5, a wide one to about 1.9:1.
  static const double minAspect = 0.8;
  static const double maxAspect = 1.91;

  static const double _wide = 1.2;

  /// The size the album takes in [width], and the rectangle of each of the
  /// [aspects]' pictures in it.
  static ({Size size, List<Rect> tiles}) of(
    List<double> aspects,
    double width,
  ) {
    assert(aspects.isNotEmpty, 'An album has a picture.');
    final first = aspects.first;
    final wideFirst = first > _wide;
    List<Rect> tiles;
    double height;
    switch (aspects.length) {
      case 1:
        height = width / first.clamp(minAspect, maxAspect);
        tiles = [Rect.fromLTWH(0, 0, width, height)];
      case 2:
        if (aspects.every((a) => a > _wide)) {
          final each = width / 1.6;
          height = each * 2 + gap;
          tiles = [
            Rect.fromLTWH(0, 0, width, each),
            Rect.fromLTWH(0, each + gap, width, each),
          ];
        } else {
          final each = (width - gap) / 2;
          height = each * 1.25;
          tiles = [
            Rect.fromLTWH(0, 0, each, height),
            Rect.fromLTWH(each + gap, 0, each, height),
          ];
        }
      case 3:
        if (wideFirst) {
          final top = width / 1.6;
          final each = (width - gap) / 2;
          height = top + gap + each * 0.8;
          tiles = [
            Rect.fromLTWH(0, 0, width, top),
            Rect.fromLTWH(0, top + gap, each, each * 0.8),
            Rect.fromLTWH(each + gap, top + gap, each, each * 0.8),
          ];
        } else {
          final left = (width - gap) * 0.62;
          final right = width - gap - left;
          height = width * 0.9;
          final half = (height - gap) / 2;
          tiles = [
            Rect.fromLTWH(0, 0, left, height),
            Rect.fromLTWH(left + gap, 0, right, half),
            Rect.fromLTWH(left + gap, half + gap, right, half),
          ];
        }
      case 4 when !wideFirst:
        final each = (width - gap) / 2;
        height = each * 2 + gap;
        tiles = [
          for (var i = 0; i < 4; i++)
            Rect.fromLTWH(
              (i % 2) * (each + gap),
              (i ~/ 2) * (each + gap),
              each,
              each,
            ),
        ];
      default:
        // A wide first picture over a row of the rest, three to a row.
        final top = width / 1.6;
        final rest = aspects.length - 1;
        final perRow = math.min(3, rest);
        final each = (width - gap * (perRow - 1)) / perRow;
        final rows = (rest / perRow).ceil();
        height = top + gap + rows * each + (rows - 1) * gap;
        tiles = [
          Rect.fromLTWH(0, 0, width, top),
          for (var i = 0; i < rest; i++)
            Rect.fromLTWH(
              (i % perRow) * (each + gap),
              top + gap + (i ~/ perRow) * (each + gap),
              each,
              each,
            ),
        ];
    }
    return (size: Size(width, height), tiles: tiles);
  }
}
