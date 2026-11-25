import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_ui/mpx_ui.dart';

void main() {
  const base = 42.0;
  const spacing = 1.0;
  const pad = 8.0;
  const maxWidth = 84.0;
  const viewport = 400.0;

  // Square pictures: 56 wide at the strip's 56 high.
  double square(int index) => 56;

  List<ViewerStripItem> layout(
    double focus, {
    int count = 8,
    double Function(int)? widthOf,
  }) => ViewerStripLayout.of(
    viewport: viewport,
    count: count,
    focus: focus,
    baseWidth: base,
    spacing: spacing,
    padding: pad,
    maxWidth: maxWidth,
    pictureWidthOf: widthOf ?? square,
  );

  ViewerStripItem item(List<ViewerStripItem> items, int index) =>
      items.singleWhere((item) => item.index == index);

  test(
    'the item in focus is as wide as its picture and a gap on each side',
    () {
      final items = layout(3);

      // 56 for a square picture, and 8 + 8 around it.
      expect(item(items, 3).width, 56 + 2 * pad);
      expect(item(items, 3).inset, pad);
    },
  );

  test('a picture is as wide as its proportion at the strip\'s height, '
      'between the base and twice the base', () {
    expect(item(layout(2, widthOf: (_) => 30), 2).width, base + 2 * pad);
    expect(item(layout(2, widthOf: (_) => 70), 2).width, 70 + 2 * pad);
    expect(item(layout(2, widthOf: (_) => 200), 2).width, maxWidth + 2 * pad);
  });

  test('the others are the base width, one apart', () {
    final items = layout(3);

    for (final other in items.where((item) => item.index != 3)) {
      expect(other.width, base);
      expect(other.inset, 0);
    }
    final ordered = [...items]..sort((a, b) => a.index.compareTo(b.index));
    for (var i = 1; i < ordered.length; i++) {
      final gap =
          ordered[i].left - (ordered[i - 1].left + ordered[i - 1].width);
      expect(gap, spacing, reason: 'items ${i - 1} and $i');
    }
  });

  test('the item in focus is in the middle', () {
    final focused = item(layout(3), 3);

    expect(focused.left + focused.width / 2, viewport / 2);
  });

  test('between two items the focus is between them: both grow by what is '
      'left and gained, the row moves by the same', () {
    final items = layout(3.5);

    // Each is half way to its enlarged width.
    expect(item(items, 3).width, base + (56 - base) / 2 + pad);
    expect(item(items, 4).width, base + (56 - base) / 2 + pad);
    // The middle is between their centres.
    final a = item(items, 3);
    final b = item(items, 4);
    final middle = ((a.left + a.width / 2) + (b.left + b.width / 2)) / 2;
    expect(middle, closeTo(viewport / 2, 0.001));
  });

  test('the row moves with the focus, linearly', () {
    final at3 = item(layout(3), 0).left;
    final at35 = item(layout(3.5), 0).left;
    final at4 = item(layout(4), 0).left;

    // 43 to the left for a step on the row of the base widths (the grown
    // items take what they take: the same at both ends).
    expect(at3 - at4, closeTo(base + spacing, 0.001));
    expect(at3 - at35, closeTo((at3 - at4) / 2, 0.001));
  });

  test('only what is on the screen is laid out', () {
    final items = layout(50, count: 100);

    expect(items.length, lessThan(20));
    expect(items.every((item) => item.left + item.width > -base), isTrue);
    expect(items.every((item) => item.left < viewport + base), isTrue);
  });

  test('the first item at rest stands where the focus puts it, not at the '
      'edge', () {
    final first = item(layout(0, count: 3), 0);

    expect(first.left + first.width / 2, viewport / 2);
  });

  test('the focus is held within the items', () {
    final items = layout(-2, count: 3);

    expect(item(items, 0).width, 56 + 2 * pad);
  });

  test('a single item has the strip to itself, centred', () {
    final items = layout(0, count: 1);

    expect(items, hasLength(1));
    expect(items.single.left + items.single.width / 2, viewport / 2);
  });

  test('the picture is what the gaps leave', () {
    final one = item(layout(3), 3);

    expect(one.pictureLeft, one.left + pad);
    expect(one.pictureWidth, 56);
    expect(item(layout(3), 5).pictureWidth, base);
  });

  group('a jump', () {
    List<ViewerStripItem> between(double t, {int from = 0, int to = 5}) =>
        ViewerStripLayout.between(
          viewport: viewport,
          count: 8,
          from: from,
          to: to,
          progress: t,
          baseWidth: base,
          spacing: spacing,
          padding: pad,
          maxWidth: maxWidth,
          pictureWidthOf: square,
        );

    test('grows the item it goes to as it shrinks the one it leaves, and no '
        'other', () {
      final items = between(0.5);

      expect(item(items, 0).width, base + (56 - base) / 2 + pad);
      expect(item(items, 5).width, base + (56 - base) / 2 + pad);
      for (final other in items.where((i) => i.index != 0 && i.index != 5)) {
        expect(other.width, base, reason: 'item ${other.index}');
      }
    });

    test('moves the row between the two, the same way at both ends', () {
      final start = item(between(0), 0);
      final end = item(between(1), 5);

      expect(start.left + start.width / 2, closeTo(viewport / 2, 0.001));
      expect(end.left + end.width / 2, closeTo(viewport / 2, 0.001));
    });

    test('with a step of one is the fractional focus', () {
      final a = between(0.5, from: 3, to: 4);
      final b = layout(3.5);

      for (final one in a) {
        expect(one.left, closeTo(item(b, one.index).left, 0.001));
        expect(one.width, closeTo(item(b, one.index).width, 0.001));
      }
    });
  });
}
