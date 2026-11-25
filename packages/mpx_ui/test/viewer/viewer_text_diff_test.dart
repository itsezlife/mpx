import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_ui/mpx_ui.dart';

void main() {
  List<(String, String?)> shape(List<ViewerTextSegment> segments) => [
    for (final s in segments) (s.next, s.previous),
  ];

  group('by words', () {
    test('a text that did not change is one stayed segment', () {
      final segments = ViewerTextDiff.byWords('Today at 5', 'Today at 5');

      expect(shape(segments), [('Today at 5', null)]);
    });

    test('the words in front that stayed stay, and the rest is swapped', () {
      final segments = ViewerTextDiff.byWords(
        'Nov 23, 2026 5:05',
        'Nov 23, 2026 5:04',
      );

      expect(shape(segments), [('Nov 23, 2026 ', null), ('5:05', '5:04')]);
    });

    test('a first word that differs swaps the whole text', () {
      final segments = ViewerTextDiff.byWords('Yesterday', 'Today');

      expect(shape(segments), [('Yesterday', 'Today')]);
    });

    test('a longer text keeps the words it has in common in front', () {
      final segments = ViewerTextDiff.byWords('2 hours ago', '2 hours');

      // The word "hours" has no space after it in the shorter text: it is
      // another word, as a word carries its space.
      expect(shape(segments), [('2 ', null), ('hours ago', 'hours')]);
    });

    test('an empty text has no segments', () {
      expect(ViewerTextDiff.byWords('', ''), isEmpty);
    });
  });

  group('by digits, from the end', () {
    test('the digits that changed are swapped, the rest stays where it is', () {
      final segments = ViewerTextDiff.fromEnd('3 of 5', '2 of 5');

      expect(shape(segments), [('3', '2'), (' of 5', null)]);
    });

    test('a number that grows takes a place in front', () {
      final segments = ViewerTextDiff.fromEnd('10 of 12', '9 of 12');

      expect(shape(segments), [('10', '9'), (' of 12', null)]);
    });

    test('a number that shrinks gives its place up', () {
      final segments = ViewerTextDiff.fromEnd('9 of 12', '10 of 12');

      expect(shape(segments), [('9', '10'), (' of 12', null)]);
    });

    test('a digit that stayed in the middle stays', () {
      final segments = ViewerTextDiff.fromEnd('1 of 15', '1 of 25');

      expect(shape(segments), [('1 of ', null), ('1', '2'), ('5', null)]);
    });

    test('the same text is one stayed segment', () {
      expect(shape(ViewerTextDiff.fromEnd('4 of 9', '4 of 9')), [
        ('4 of 9', null),
      ]);
    });
  });
}
