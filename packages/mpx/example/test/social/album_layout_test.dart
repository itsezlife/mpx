import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_example/social/src/feature/timeline/widget/album_layout.dart';

void main() {
  const width = 400.0;

  test('a lone picture keeps its proportion within limits', () {
    expect(AlbumLayout.of([1.0], width).size.height, closeTo(400, 0.01));
    // A tall one is cut to 4:5, a wide one to about 1.9:1.
    expect(AlbumLayout.of([0.3], width).size.height, closeTo(500, 0.01));
    expect(
      AlbumLayout.of([3.0], width).size.height,
      closeTo(width / AlbumLayout.maxAspect, 0.01),
    );
  });

  test('two wide pictures stack, others sit side by side', () {
    final stacked = AlbumLayout.of([1.6, 1.8], width);
    expect(stacked.tiles[0].width, width);
    expect(stacked.tiles[1].top, greaterThan(stacked.tiles[0].bottom));

    final beside = AlbumLayout.of([0.8, 1.0], width);
    expect(beside.tiles[0].top, beside.tiles[1].top);
    expect(beside.tiles[1].left, greaterThan(beside.tiles[0].right));
  });

  for (final aspects in <List<double>>[
    [1.0],
    [1.6, 1.6],
    [0.8, 1.0],
    [1.6, 1.0, 1.0],
    [0.8, 1.0, 1.0],
    [0.8, 1.0, 1.0, 1.0],
    [1.6, 1.0, 1.0, 1.0],
    [1.0, 1.0, 1.0, 1.0, 1.0, 1.0],
  ]) {
    test(
      '${aspects.length} tiles of $aspects fit inside and do not overlap',
      () {
        final layout = AlbumLayout.of(aspects, width);
        expect(layout.tiles, hasLength(aspects.length));
        final bounds = Offset.zero & layout.size;
        for (final tile in layout.tiles) {
          expect(tile.left, greaterThanOrEqualTo(-0.001));
          expect(tile.top, greaterThanOrEqualTo(-0.001));
          expect(tile.right, lessThanOrEqualTo(bounds.right + 0.001));
          expect(tile.bottom, lessThanOrEqualTo(bounds.bottom + 0.001));
        }
        for (var i = 0; i < layout.tiles.length; i++) {
          for (var j = i + 1; j < layout.tiles.length; j++) {
            final overlap = layout.tiles[i].intersect(layout.tiles[j]);
            expect(
              overlap.width <= 0.001 || overlap.height <= 0.001,
              isTrue,
              reason: 'tiles $i and $j overlap: $overlap',
            );
          }
        }
      },
    );
  }
}
