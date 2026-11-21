import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_ui/mpx_ui.dart';

MediaKey _key(int i) => MediaKey.remote('strip-$i');

// A row that scrolls by jumps, as a scroll controller's would.
final class _Row implements PickerStripScrollTarget {
  _Row(this.maxOffset);

  @override
  double offset = 0;

  @override
  final double maxOffset;

  @override
  bool get ready => true;

  @override
  void jumpTo(double offset) => this.offset = offset;
}

void main() {
  group('the edge rule', () {
    const policy = PickerStripPolicy.$Android;

    test('nothing outside the 32 px reach', () {
      expect(policy.edgeDelta(32, 300), 0);
      expect(policy.edgeDelta(150, 300), 0);
      expect(policy.edgeDelta(268, 300), 0);
    });

    test('(1 - d / 32) * 6 toward the near end', () {
      expect(policy.edgeDelta(16, 300), -3);
      expect(policy.edgeDelta(0, 300), -6);
      expect(policy.edgeDelta(300 - 8, 300), 4.5);
      expect(policy.edgeDelta(310, 300), 6, reason: 'past the end');
    });
  });

  group('the controller', () {
    late OrderedPickerSelection selection;
    late List<(MediaKey, int)> moves;
    late PickerStripController strip;

    setUp(() {
      selection = OrderedPickerSelection();
      for (var i = 0; i < 10; i++) {
        selection.toggle(_key(i));
      }
      moves = [];
      strip = PickerStripController(
        selection: selection,
        onReorder: (key, to) {
          moves.add((key, to));
          selection.move(key, to);
        },
      );
    });

    tearDown(() => strip.dispose());

    testWidgets('a deselected item leaves from its place for 120 ms', (
      tester,
    ) async {
      selection.toggle(_key(2));
      expect(strip.keys, isNot(contains(_key(2))));
      expect(strip.leaving, {_key(2): 2});
      await tester.pump(const Duration(milliseconds: 100));
      expect(strip.leaving, {_key(2): 2});
      await tester.pump(const Duration(milliseconds: 30));
      expect(strip.leaving, isEmpty);
    });

    testWidgets('selected again while leaving, it is no longer leaving', (
      tester,
    ) async {
      selection.toggle(_key(2));
      selection.toggle(_key(2));
      expect(strip.leaving, isEmpty);
      expect(strip.keys.last, _key(2));
      await tester.pump(const Duration(milliseconds: 200));
      expect(strip.leaving, isEmpty);
    });

    test('the row is as long as its items without the last gap', () {
      expect(strip.length, 10 * 91 - 6);
      expect(strip.startOf(3), 273);
    });

    testWidgets('a held item moves to the place under the finger, and near '
        'the end the row scrolls under it until it is put down', (
      tester,
    ) async {
      final row = _Row(500);
      strip
        ..target = row
        ..lift(_key(0))
        // Over the third place: 6 + 2 * 91 + 10.
        ..hold(198, 300);
      expect(moves, [(_key(0), 2)]);
      // 8 from the end: 4.5 a tick.
      strip.hold(292, 300);
      await tester.pump(const Duration(milliseconds: 150));
      expect(row.offset, closeTo(45, 4.5));
      expect(selection.keys.indexOf(_key(0)), greaterThan(2));
      strip.drop();
      final rest = row.offset;
      await tester.pump(const Duration(milliseconds: 150));
      expect(row.offset, rest);
      expect(strip.lifted, isNull);
    });

    test('nothing lifts without a reorder', () {
      final fixed = PickerStripController(selection: selection)..lift(_key(0));
      addTearDown(fixed.dispose);
      expect(fixed.lifted, isNull);
    });
  });
}
