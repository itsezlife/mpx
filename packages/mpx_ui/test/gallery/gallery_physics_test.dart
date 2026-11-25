import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_ui/mpx_ui.dart';

const _android = GalleryPagerPhysics.$Android;
const _ios = GalleryPagerPhysics.$IOS;

void main() {
  group('claims', () {
    test('a margin claims once the drag is that much longer along', () {
      const claim = GalleryClaim.margin(12);
      expect(claim.claims(19, 7), isFalse);
      expect(claim.claims(20, 7), isTrue);
      expect(claim.claims(-20, -7), isTrue);
      expect(claim.claims(12, 0), isFalse);
    });

    test('a dominant claim needs its slop and its ratio', () {
      const claim = GalleryClaim.dominant(slop: 30, ratio: 2);
      expect(claim.claims(29, 0), isFalse);
      expect(claim.claims(30, 14), isTrue);
      expect(claim.claims(30, 15), isFalse);
      expect(const GalleryClaim.none().claims(1000, 0), isFalse);
    });
  });

  group('edges', () {
    test('damped follows a share; a rubber band never passes a page', () {
      expect(const GalleryEdge.damped(1 / 3).follow(90, 400), 30);
      const band = GalleryEdge.rubberBand();
      expect(band.follow(100, 400), closeTo(48.35, 0.01));
      expect(band.follow(-100, 400), closeTo(-48.35, 0.01));
      expect(band.follow(100000, 400), lessThan(400));
      expect(const GalleryEdge.hard().follow(100, 400), 0);
    });
  });

  group('release', () {
    test('Android: a third of a page or 650 px/s, the next checked first', () {
      int release(double fraction, double velocity, {bool zoomed = false}) =>
          _android.release(
            fraction: fraction,
            velocity: velocity,
            canNext: true,
            canPrevious: true,
            zoomed: zoomed,
          );
      expect(release(0.33, 0), 0);
      expect(release(1 / 3, 0), 1);
      expect(release(-1 / 3, 0), -1);
      expect(release(0.05, 649), 0);
      expect(release(0.05, 650), 1);
      expect(release(-0.05, -650), -1);
      // A drag a zoomed picture handed on pages by distance only.
      expect(release(0.05, 5000, zoomed: true), 0);
      expect(release(0.34, 0, zoomed: true), 1);
    });

    test('no page that way, no step', () {
      expect(
        _android.release(
          fraction: 0.9,
          velocity: 0,
          canNext: false,
          canPrevious: true,
        ),
        0,
      );
    });

    test('iOS: half a page, or a flick; the velocity counts while zoomed', () {
      int release(double fraction, double velocity) => _ios.release(
        fraction: fraction,
        velocity: velocity,
        canNext: true,
        canPrevious: true,
        zoomed: true,
      );
      expect(release(0.49, 0), 0);
      expect(release(0.5, 0), 1);
      expect(release(0.1, 300), 1);
    });
  });

  group('side taps', () {
    test('Android: an eighth of the width, at most 135 physical px', () {
      final side = _android.sideTap!;
      expect(side.widthIn(400, 1), 50);
      expect(side.widthIn(1440, 1), 135);
      expect(side.widthIn(1440, 3), 45);
      expect(
        side.directionAt(const Offset(10, 400), const Size(400, 800), 1),
        -1,
      );
      expect(
        side.directionAt(const Offset(395, 400), const Size(400, 800), 1),
        1,
      );
      expect(
        side.directionAt(const Offset(200, 400), const Size(400, 800), 1),
        0,
      );
      // Not over the bars.
      expect(
        side.directionAt(const Offset(10, 60), const Size(400, 800), 1),
        0,
      );
    });

    test('desktop: 90 px strips on the press, clear of 47 px bars', () {
      final side = GalleryPagerPhysics.$Desktop.sideTap!;
      expect(side.onPress, isTrue);
      expect(side.widthIn(1200, 2), 90);
      expect(
        side.directionAt(const Offset(80, 30), const Size(1200, 800), 1),
        0,
      );
      expect(
        side.directionAt(const Offset(80, 400), const Size(1200, 800), 1),
        -1,
      );
    });
  });

  group('transitions', () {
    test('a strip places pages a stride apart, the content lagging', () {
      const strip = GalleryPageTransition.strip(parallax: 0.16);
      final next = strip.place(0.5, 440);
      expect(next.offset, 220);
      expect(next.contentShift, closeTo(-35.2, 1e-9));
      expect(next.opacity, 1);
      expect(strip.place(1, 440).shows, isFalse);
    });

    test('a stack keeps the next page under, shrinking and fading', () {
      const stack = GalleryPageTransition.stack();
      final current = stack.place(-0.25, 415);
      expect(current.offset, -0.25 * 415);
      expect(current.under, isFalse);
      final next = stack.place(0.75, 415);
      expect(next.offset, 0);
      expect(next.under, isTrue);
      expect(next.scale, closeTo(0.775, 1e-9));
      expect(next.opacity, closeTo(0.25, 1e-9));
      // At rest the next page is not drawn at all.
      expect(stack.place(1, 415).shows, isFalse);
      // Past an end the edge page follows the drag alone.
      expect(stack.place(0.1, 415, edge: true).offset, closeTo(41.5, 1e-9));
    });

    test('instant shows only the nearest page, in place', () {
      const instant = GalleryPageTransition.instant();
      expect(instant.place(0.4, 400).shows, isTrue);
      expect(instant.place(0.6, 400).shows, isFalse);
      expect(instant.place(0.4, 400).offset, 0);
    });
  });

  group('the standard values', () {
    test('per platform', () {
      expect(_android.claim, const GalleryClaim.margin(12));
      expect(_android.settleDuration, const Duration(milliseconds: 250));
      expect(_android.edge, const GalleryEdge.damped(1 / 3));
      expect(_android.catchesSettle, isFalse);
      expect(_ios.claim, const GalleryClaim.dominant(slop: 10));
      expect(_ios.edge, const GalleryEdge.rubberBand());
      expect(_ios.catchesSettle, isTrue);
      expect(GalleryPagerPhysics.$Desktop.claim, const GalleryClaim.none());
      expect(GalleryPagerPhysics.$Desktop.settleDuration, Duration.zero);
      expect(GalleryPagerPhysics.$Desktop.handOff, isFalse);
      expect(ViewerPolicy.$Android.pageGap, 15);
      expect(ViewerPolicy.$IOS.pageGap, 40);
      expect(
        ViewerPolicy.$Android.transition,
        const GalleryPageTransition.stack(),
      );
      expect(
        ViewerPolicy.$IOS.transition,
        const GalleryPageTransition.strip(parallax: 0.16),
      );
      expect(
        ViewerPolicy.$Desktop.transition,
        const GalleryPageTransition.instant(),
      );
    });

    test('copyWith keeps every field not given', () {
      final changed = _android.copyWith(releaseFraction: 0.5);
      expect(changed.releaseFraction, 0.5);
      expect(changed.copyWith(releaseFraction: 1 / 3), _android);
    });
  });
}
