import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';

void main() {
  Rect bounds(String data) => SvgPathData.parse(data)!.getBounds();

  group('SvgPathData', () {
    test('moves and lines, absolute and relative', () {
      expect(
        bounds('M10 10 L20 10 L20 30 Z'),
        const Rect.fromLTRB(10, 10, 20, 30),
      );
      expect(
        bounds('m10 10 l10 0 l0 20 z'),
        const Rect.fromLTRB(10, 10, 20, 30),
      );
    });

    test('a move followed by pairs draws lines through them', () {
      expect(bounds('M0 0 10 0 10 10z'), const Rect.fromLTRB(0, 0, 10, 10));
      expect(bounds('m5 5 10 0 0 10z'), const Rect.fromLTRB(5, 5, 15, 15));
    });

    test('horizontal and vertical lines, with implicit repeats', () {
      expect(bounds('M0 0H10V20H0Z'), const Rect.fromLTRB(0, 0, 10, 20));
      expect(bounds('M2 2h4v4h-4z'), const Rect.fromLTRB(2, 2, 6, 6));
      expect(bounds('M0 0H5 10V3 7Z'), const Rect.fromLTRB(0, 0, 10, 7));
    });

    test('cubic curves and their smooth continuation', () {
      final cubic = SvgPathData.parse('M0 0C0 10 10 10 10 0Z')!;
      expect(cubic.contains(const Offset(5, 5)), isTrue);
      expect(cubic.contains(const Offset(5, 9)), isFalse);
      expect(bounds('M0 0c0 10 10 10 10 0z').right, closeTo(10, 0.01));
      final smooth = SvgPathData.parse('M0 0C0 10 10 10 10 0S20 -10 20 0Z')!;
      expect(smooth.getBounds().right, closeTo(20, 0.01));
      expect(smooth.getBounds().top, lessThan(-5));
      expect(
        SvgPathData.parse('M0 0c0 10 10 10 10 0s10 -10 10 0z')!.getBounds(),
        smooth.getBounds(),
      );
    });

    test('quadratic curves and their smooth continuation', () {
      final quad = SvgPathData.parse('M0 0Q5 10 10 0Z')!;
      // The curve peaks halfway to its control point.
      expect(quad.contains(const Offset(5, 4.8)), isTrue);
      expect(quad.contains(const Offset(5, 5.3)), isFalse);
      final smooth = SvgPathData.parse('M0 0Q5 10 10 0T20 0Z')!;
      // The mirrored control point bends the second half the other way.
      expect(smooth.contains(const Offset(15, -4.8)), isTrue);
      expect(smooth.contains(const Offset(15, -5.3)), isFalse);
      expect(
        SvgPathData.parse('M0 0q5 10 10 0t10 0z')!.getBounds(),
        smooth.getBounds(),
      );
    });

    test('numbers in every form: signs, decimals, exponents, no spaces', () {
      expect(
        bounds('M.5.5L1e1,-.5e0l-1.5-0Z'),
        const Rect.fromLTRB(0.5, -0.5, 10, 0.5),
      );
      expect(bounds('M0,0L10,10'), const Rect.fromLTRB(0, 0, 10, 10));
    });

    test('several subpaths', () {
      expect(bounds('M0 0h1v1zM9 9h1v1z'), const Rect.fromLTRB(0, 0, 10, 10));
    });

    test('rejects arcs, garbage and an empty path', () {
      expect(SvgPathData.parse('M0 0A5 5 0 0 1 10 0Z'), isNull);
      expect(SvgPathData.parse('M0 0a5 5 0 0 1 10 0z'), isNull);
      expect(SvgPathData.parse('hello'), isNull);
      expect(SvgPathData.parse('M0'), isNull);
      expect(SvgPathData.parse('L0 0'), isNull);
      expect(SvgPathData.parse(''), isNull);
      expect(SvgPathData.parse('M0 0L1'), isNull);
    });
  });
}
