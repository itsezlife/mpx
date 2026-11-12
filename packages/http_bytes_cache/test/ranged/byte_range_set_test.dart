import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:test/test.dart';

void main() {
  group('ByteRangeSet', () {
    test('overlapping and touching spans merge', () {
      final set = ByteRangeSet.empty
          .add(0, 100)
          .add(50, 150)
          .add(200, 300)
          .add(150, 160);

      expect(set.spans, [(0, 160), (200, 300)]);
      expect(set.coveredBytes, 260);
    });

    test('a span bridging two others joins them', () {
      final set = ByteRangeSet.empty.add(0, 10).add(20, 30).add(5, 25);

      expect(set.spans, [(0, 30)]);
    });

    test('covers asks for every byte of a range', () {
      final set = ByteRangeSet.empty.add(10, 20).add(30, 40);

      expect(set.covers(10, 20), isTrue);
      expect(set.covers(12, 18), isTrue);
      expect(set.covers(15, 35), isFalse);
      expect(set.covers(0, 5), isFalse);
    });

    test('firstGap finds the first missing span inside a range', () {
      final set = ByteRangeSet.empty.add(10, 20).add(30, 40);

      expect(set.firstGap(0, 50), (0, 10));
      expect(set.firstGap(10, 50), (20, 30));
      expect(set.firstGap(12, 18), isNull);
      expect(set.firstGap(35, 50), (40, 50));
    });

    test('contiguousFrom is how far the bytes run unbroken from an offset', () {
      final set = ByteRangeSet.empty.add(10, 20).add(30, 40);

      expect(set.contiguousFrom(12), 20);
      expect(set.contiguousFrom(20), 20);
      expect(set.contiguousFrom(5), 5);
    });

    test('flat list round trip and equality', () {
      final set = ByteRangeSet.empty.add(5, 9).add(100, 200);

      expect(set.toFlatList(), [5, 9, 100, 200]);
      expect(ByteRangeSet.fromFlatList(const [5, 9, 100, 200]), set);
      expect(
        () => ByteRangeSet.fromFlatList(const [5, 9, 7]),
        throwsFormatException,
      );
    });
  });
}
