import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_ui/mpx_ui.dart';

MediaKey _k(int i) => MediaKey.external('device-library:$i');

void main() {
  test('order numbers follow selection and re-number on removal', () {
    final selection = OrderedPickerSelection();
    var notified = 0;
    selection.addListener(() => notified++);
    expect(selection.toggle(_k(5)), isA<PickerToggle$Selected>());
    selection
      ..toggle(_k(2))
      ..toggle(_k(9));
    expect([_k(5), _k(2), _k(9)].map(selection.orderOf), [1, 2, 3]);
    expect(selection.toggle(_k(5)), isA<PickerToggle$Deselected>());
    expect(selection.orderOf(_k(5)), isNull);
    expect(selection.orderOf(_k(2)), 1);
    expect(selection.orderOf(_k(9)), 2);
    expect(selection.keys, [_k(2), _k(9)]);
    expect(notified, 4);
  });

  test('the cap refuses and changes nothing', () {
    final selection = OrderedPickerSelection(cap: 2)
      ..toggle(_k(1))
      ..toggle(_k(2));
    final result = selection.toggle(_k(3));
    expect(
      result,
      isA<PickerToggle$Refused>().having(
        (r) => r.reason,
        'reason',
        PickerRefusal.cap,
      ),
    );
    expect(selection.keys, hasLength(2));
    expect(selection.refusalOf(_k(3)), PickerRefusal.cap);
    expect(selection.refusalOf(_k(1)), isNull, reason: 'selected keys pass');
  });

  test("the host's gate refuses with its reason", () {
    final selection = OrderedPickerSelection(
      gate: (key) => key == _k(7) ? PickerRefusal.kind : null,
    );
    expect(
      (selection.toggle(_k(7)) as PickerToggle$Refused).reason,
      PickerRefusal.kind,
    );
    expect(selection.toggle(_k(8)), isA<PickerToggle$Selected>());
  });

  test('single select replaces the selected key', () {
    final selection = OrderedPickerSelection(single: true)
      ..toggle(_k(1))
      ..toggle(_k(2));
    expect(selection.keys, [_k(2)]);
    expect(selection.orderOf(_k(2)), 1);
  });

  test('a range takes the state the first key takes', () {
    final selection = OrderedPickerSelection(
      cap: 3,
      gate: (key) => key == _k(4) ? PickerRefusal.other : null,
    )..toggle(_k(2));
    var refusals = selection.toggleRange([_k(1), _k(2), _k(3), _k(4), _k(5)]);
    expect(selection.keys, [_k(2), _k(1), _k(3)]);
    expect(refusals, [
      (_k(4), PickerRefusal.other),
      (_k(5), PickerRefusal.cap),
    ]);
    refusals = selection.toggleRange([_k(3), _k(1)]);
    expect(selection.keys, [_k(2)], reason: 'the first was selected: off');
    expect(refusals, isEmpty);
    selection.toggleRange([_k(2), _k(6)], to: true);
    expect(selection.keys, [_k(2), _k(6)]);
  });

  test('a move puts a key at a new place and re-numbers the rest', () {
    final selection = OrderedPickerSelection()
      ..toggle(_k(1))
      ..toggle(_k(2))
      ..toggle(_k(3))
      ..toggle(_k(4));
    var notified = 0;
    selection.addListener(() => notified++);
    selection.move(_k(1), 2);
    expect(selection.keys, [_k(2), _k(3), _k(1), _k(4)]);
    expect(selection.orderOf(_k(1)), 3);
    expect(selection.orderOf(_k(3)), 2);
    selection.move(_k(4), 0);
    expect(selection.keys, [_k(4), _k(2), _k(3), _k(1)]);
    expect(notified, 2);
    // A key not selected, or one already in place, changes nothing.
    selection
      ..move(_k(9), 0)
      ..move(_k(4), 0);
    expect(notified, 2);
  });
}
