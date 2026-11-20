import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_library/mpx_library.dart';
import 'package:mpx_library/testing.dart';
import 'package:mpx_ui/mpx_ui.dart';

import 'library_picker_test.dart';

double _opacityOver(WidgetTester tester, int index) {
  final opacities = tester.widgetList<Opacity>(
    find.descendant(of: cell(index), matching: find.byType(Opacity)),
  );
  return opacities.map((o) => o.opacity).reduce((a, b) => a * b);
}

Future<void> _open(WidgetTester tester, int index) async {
  await tester.tap(cell(index));
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _close(WidgetTester tester) async {
  // Not awaited: the close runs as the test pumps frames.
  // ignore: unawaited_futures
  tester.state<MediaViewerState>(find.byType(MediaViewer)).close();
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('a picture tap opens the viewer on that item', (tester) async {
    final h = PickerHarness();
    await h.pump(tester, viewerSlot: true);
    await _open(tester, 2);
    expect(find.byType(MediaViewer), findsOneWidget);
    expect(h.slotItems.last.index, 2);
    expect(h.slotItems.last.asset, FakeMediaLibrary.assetAt(2));
    await _close(tester);
    expect(find.byType(MediaViewer), findsNothing);
  });

  testWidgets('the check toggles the shared selection and shows the order', (
    tester,
  ) async {
    final h = PickerHarness();
    await h.pump(tester, viewerSlot: true);
    h.selection.toggle(key(0));
    await _open(tester, 2);
    await tester.tap(find.byKey(const ValueKey('mpx-picker-viewer-check')));
    await tester.pump();
    expect(h.selection.keys, [key(0), key(2)]);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('mpx-picker-viewer-check')),
        matching: find.text('2'),
      ),
      findsOneWidget,
    );
    expect(h.slotItems.last.keys, [key(0), key(2)]);
    await tester.tap(find.byKey(const ValueKey('mpx-picker-viewer-counter')));
    await tester.pump();
    expect(find.byType(ListView), findsWidgets, reason: 'the selected strip');
    // The strip's thumbnails are told to the cache, so their keys resolve.
    final strip = tester.widgetList<ContentView>(
      find.descendant(
        of: find.byType(ListView).last,
        matching: find.byType(ContentView),
      ),
    );
    expect(strip, hasLength(2));
    final known = h.producer.known.map((d) => d.key).toSet();
    for (final view in strip) {
      expect(known, contains(view.content));
    }
    await _close(tester);
  });

  testWidgets('the picker chrome fades out as a dismiss drag starts', (
    tester,
  ) async {
    final h = PickerHarness();
    await h.pump(tester, viewerSlot: true);
    h.selection.toggle(key(0));
    await _open(tester, 2);
    double chromeOpacity() => tester
        .widgetList<FadeTransition>(
          find.ancestor(
            of: find.byKey(const ValueKey('mpx-picker-viewer-check')),
            matching: find.byType(FadeTransition),
          ),
        )
        .map((f) => f.opacity.value)
        .reduce((a, b) => a * b);
    expect(chromeOpacity(), 1);

    final gesture = await tester.startGesture(const Offset(195, 400));
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(chromeOpacity(), 0);
    // Faded out, it takes no taps.
    await tester.tap(
      find.byKey(const ValueKey('mpx-picker-viewer-check')),
      warnIfMissed: false,
    );
    expect(h.selection.keys, [key(0)]);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('the check goes through the gate', (tester) async {
    final h = PickerHarness();
    final gated = OrderedPickerSelection(
      gate: (k) => k == key(2) ? PickerRefusal.kind : null,
    );
    await h.pump(tester, viewerSlot: true, picker: gated);
    await _open(tester, 2);
    await tester.tap(find.byKey(const ValueKey('mpx-picker-viewer-check')));
    await tester.pump();
    expect(gated.keys, isEmpty);
    expect(h.refusals, [(key(2), PickerRefusal.kind)]);
    await _close(tester);
  });

  testWidgets('with nothing checked the slot takes the item shown', (
    tester,
  ) async {
    final h = PickerHarness();
    await h.pump(tester, viewerSlot: true);
    await _open(tester, 1);
    expect(h.slotItems.last.keys, [key(1)]);
    await _close(tester);
  });

  testWidgets('the cell under the viewer hides and comes back', (tester) async {
    final h = PickerHarness();
    await h.pump(tester, viewerSlot: true);
    expect(_opacityOver(tester, 1), 1);
    await _open(tester, 1);
    expect(_opacityOver(tester, 1), 0);
    await _close(tester);
    expect(_opacityOver(tester, 1), 1);
  });

  testWidgets(r'$Android holds library changes while the viewer is open', (
    tester,
  ) async {
    final h = PickerHarness();
    await h.pump(tester, viewerSlot: true);
    await _open(tester, 0);
    h.library.insert([
      const LibraryAsset(
        id: LibraryAssetId('new'),
        kind: LibraryAssetKind.photo,
      ),
    ]);
    await tester.pump(const Duration(milliseconds: 100));
    final grid = tester.state<LibraryGridState>(find.byType(LibraryGrid));
    expect(grid.pages.total, 30, reason: 'held');
    await _close(tester);
    expect(grid.pages.total, 31);
  });
}
