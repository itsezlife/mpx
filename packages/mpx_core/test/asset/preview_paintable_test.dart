import 'dart:ui';

import 'package:flutter/animation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';

/// Keeps every path drawn, with its paint.
final class _Paths implements Canvas {
  final List<({Path path, Paint paint})> drawn = [];

  @override
  void drawPath(Path path, Paint paint) =>
      drawn.add((path: path, paint: paint));

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  // A square in the top-left quarter of a 100 x 100 view box.
  final outline = OutlinePaintable(
    SvgPathData.parse('M0 0H50V50H0Z')!,
    const Size(100, 100),
  );

  group('OutlinePaintable', () {
    test('places the outline as the content would be, filled as the surface '
        'says', () {
      final canvas = _Paths();

      outline.paint(
        canvas,
        const Rect.fromLTWH(0, 0, 200, 100),
        const AssetPaintContext(
          outline: OutlineLook(fill: Color(0x40748391)),
          opacity: 0.5,
        ),
      );

      final (:path, :paint) = canvas.drawn.single;
      // Contain: a 100 x 100 square centred in the 200 x 100 box.
      expect(path.getBounds(), const Rect.fromLTWH(50, 0, 50, 50));
      expect(
        paint.color.toARGB32(),
        const Color(0x40748391).withValues(alpha: 0.25 * 0.5).toARGB32(),
      );
    });

    test('without a look, fills in the tint, else a quiet grey', () {
      final tinted = _Paths();
      final bare = _Paths();
      const box = Rect.fromLTWH(0, 0, 100, 100);

      outline
        ..paint(tinted, box, const AssetPaintContext(tint: Color(0xFF112233)))
        ..paint(bare, box, const AssetPaintContext());

      expect(tinted.drawn.single.paint.color.toARGB32(), 0xFF112233);
      expect(bare.drawn.single.paint.color.toARGB32(), 0x46000000);
    });

    test('a highlight draws a second pass with a gradient', () {
      final canvas = _Paths();

      outline.paint(
        canvas,
        const Rect.fromLTWH(0, 0, 100, 100),
        const AssetPaintContext(
          outline: OutlineLook(fill: Color(0x46000000), highlight: 0.5),
        ),
      );

      expect(canvas.drawn, hasLength(2));
      expect(canvas.drawn.last.paint.shader, isNotNull);
    });

    test('is a still with the view box as its proportion', () {
      expect(outline.isAnimated, isFalse);
      expect(outline.pictureSize, const Size(100, 100));
    });
  });

  group('OutlineShimmer', () {
    test('iOS sweeps across in 1.3 s, easing out, with no rest', () {
      final shimmer = MediaStageStyle.$IOS.outlineShimmer!;
      expect(shimmer.phaseAt(Duration.zero), 0);
      expect(
        shimmer.phaseAt(const Duration(milliseconds: 650)),
        Curves.easeOut.transform(0.5),
      );
      expect(shimmer.phaseAt(const Duration(milliseconds: 1300)), 0);
    });

    test('desktop slides for a second and rests for a second', () {
      final shimmer = MediaStageStyle.$Desktop.outlineShimmer!;
      expect(shimmer.phaseAt(const Duration(milliseconds: 500)), 0.5);
      expect(shimmer.phaseAt(const Duration(milliseconds: 1500)), isNull);
      expect(shimmer.phaseAt(const Duration(milliseconds: 2250)), 0.25);
    });

    test('Android has none', () {
      expect(MediaStageStyle.$Android.outlineShimmer, isNull);
    });
  });
}
