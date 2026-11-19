import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_ui/mpx_ui.dart';

void main() {
  group('LibraryGridPolicy', () {
    test(r'$Android columns, gap and padding', () {
      const policy = LibraryGridPolicy.$Android;
      expect(policy.columnsFor(const Size(400, 800)), 3);
      expect(policy.columnsFor(const Size(800, 400)), 4);
      expect(
        policy.columnsFor(const Size(500, 800), screen: const Size(800, 1200)),
        4,
        reason: 'a tablet',
      );
      // 400 - 2 * 2 padding - 2 * 2 gaps = 392, over 3.
      expect(policy.cellExtent(400, 3), closeTo(130.667, 0.001));
      expect(policy.firstRowCornerRadius, 16);
      expect(
        (policy.checkSize, policy.checkFrame, policy.checkHitSize),
        (24, 26, 42),
      );
      expect(policy.selectedImageScale, 0.787);
      expect(policy.selectionDuration, const Duration(milliseconds: 200));
      expect(policy.disabledOpacity, 0.3);
    });

    test(r'$IOS columns and floored cells', () {
      const policy = LibraryGridPolicy.$IOS;
      expect(policy.columnsFor(const Size(390, 800)), 3);
      expect(policy.columnsFor(const Size(800, 390)), 5);
      expect(policy.cellExtent(390, 3), 129, reason: 'floor((390 - 2) / 3)');
      expect(policy.cellExtent(844, 5), 168, reason: 'floor((844 - 4) / 5)');
      expect(policy.checkSize, 29);
      expect(policy.checkHitSize, 45, reason: 'slop 8 around 29');
      expect(policy.checkSpring, const Duration(milliseconds: 500));
    });

    test('camera slot placement', () {
      expect(
        LibraryGridPolicy.$Android.showsCameraSlot(
          isAllMedia: true,
          columns: 4,
        ),
        isTrue,
      );
      expect(
        LibraryGridPolicy.$Android.showsCameraSlot(
          isAllMedia: false,
          columns: 3,
        ),
        isFalse,
      );
      expect(
        LibraryGridPolicy.$IOS.showsCameraSlot(isAllMedia: true, columns: 3),
        isTrue,
      );
      expect(
        LibraryGridPolicy.$IOS.showsCameraSlot(isAllMedia: true, columns: 5),
        isFalse,
      );
    });

    test('forPlatform', () {
      expect(
        LibraryGridPolicy.forPlatform(TargetPlatform.iOS),
        same(LibraryGridPolicy.$IOS),
      );
      expect(
        LibraryGridPolicy.forPlatform(TargetPlatform.android),
        same(LibraryGridPolicy.$Android),
      );
    });
  });

  group('LibraryGridLayout', () {
    const withCamera = LibraryGridLayout(
      columns: 3,
      extent: 100,
      gap: 2,
      cameraSlot: true,
      reverseCrossAxis: false,
      crossAxisExtent: 304,
    );

    test('the camera slot spans one column and two rows', () {
      final camera = withCamera.getGeometryForChildIndex(0);
      expect(camera.scrollOffset, 0);
      expect(camera.crossAxisOffset, 0);
      expect(camera.mainAxisExtent, 202);
      expect(camera.crossAxisExtent, 100);
      expect(
        [for (var i = 0; i < 9; i++) withCamera.cellOf(i)],
        [
          (0, 0),
          (0, 1),
          (0, 2),
          (1, 1),
          (1, 2),
          (2, 0),
          (2, 1),
          (2, 2),
          (3, 0),
        ],
      );
      final fifth = withCamera.getGeometryForChildIndex(5);
      expect(fifth.scrollOffset, 204);
      expect(fifth.crossAxisOffset, 0);
    });

    test('child index bounds per scroll offset', () {
      expect(withCamera.getMinChildIndexForScrollOffset(150), 0);
      expect(withCamera.getMaxChildIndexForScrollOffset(150), 4);
      expect(withCamera.getMinChildIndexForScrollOffset(210), 5);
      expect(withCamera.getMaxChildIndexForScrollOffset(210), 7);
      expect(withCamera.computeMaxScrollOffset(1 + 4), 202);
      expect(withCamera.computeMaxScrollOffset(1 + 5), 304);
    });

    test('right to left mirrors the columns', () {
      const rtl = LibraryGridLayout(
        columns: 3,
        extent: 100,
        gap: 2,
        cameraSlot: true,
        reverseCrossAxis: true,
        crossAxisExtent: 304,
      );
      expect(rtl.getGeometryForChildIndex(0).crossAxisOffset, 204);
      expect(rtl.getGeometryForChildIndex(2).crossAxisOffset, 0);
    });

    test('without a camera the cells flow from index 0', () {
      const plain = LibraryGridLayout(
        columns: 4,
        extent: 50,
        gap: 0,
        cameraSlot: false,
        reverseCrossAxis: false,
        crossAxisExtent: 200,
      );
      expect(plain.cellOf(5), (1, 1));
      expect(plain.getMinChildIndexForScrollOffset(120), 8);
      expect(plain.getMaxChildIndexForScrollOffset(120), 11);
      expect(plain.computeMaxScrollOffset(9), 150);
    });
  });
}
