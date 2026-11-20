import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_library/mpx_library.dart';
import 'package:mpx_library/testing.dart';
import 'package:mpx_ui/mpx_ui.dart';
import 'package:mpx_ui/testing.dart';

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
  expectThemedText(tester);
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

  testWidgets('a back press fades the picker chrome as the close starts', (
    tester,
  ) async {
    final h = PickerHarness();
    await h.pump(tester, viewerSlot: true);
    await _open(tester, 2);
    final check = find.byKey(const ValueKey('mpx-picker-viewer-check'));
    double opacity() => tester
        .widgetList<FadeTransition>(
          find.ancestor(of: check, matching: find.byType(FadeTransition)),
        )
        .map((f) => f.opacity.value)
        .reduce((a, b) => a * b);
    expect(opacity(), 1);
    Navigator.of(tester.element(check)).maybePop().ignore();
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(opacity(), lessThan(1));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byType(MediaViewer), findsNothing);
  });

  testWidgets('the check and the count stand at the top end on one line: '
      'a filled numbered circle, and an outlined pill', (tester) async {
    final h = PickerHarness();
    await h.pump(tester, viewerSlot: true);
    h.selection
      ..toggle(key(0))
      ..toggle(key(2));
    await _open(tester, 2);
    final check = find.byKey(const ValueKey('mpx-picker-viewer-check-mark'));
    final counter = find.byKey(const ValueKey('mpx-picker-viewer-counter'));
    const width = 390.0;
    // Android: a 34 dp check 11 dp from the end, 71 dp down; the count's
    // pill ends 64 dp from the end, centred on the check's line.
    expect(tester.getSize(check), const Size.square(34));
    expect(tester.getTopRight(check), const Offset(width - 11, 71));
    final pill = tester.getRect(counter);
    expect(pill.right, width - 64);
    expect(pill.height, 28);
    expect(pill.center.dy, tester.getCenter(check).dy);
    final box = tester.widget<DecoratedBox>(
      find.descendant(of: counter, matching: find.byType(DecoratedBox)),
    );
    final decoration = box.decoration as BoxDecoration;
    expect(decoration.color, isNull, reason: 'outlined, not filled');
    expect((decoration.border! as Border).top.width, 2);
    final count = tester.widget<RichText>(
      find.descendant(of: counter, matching: find.byType(RichText)),
    );
    expect(count.text.toPlainText(), '2');
    expect(count.text.style!.fontSize, 15);
    expect(count.text.style!.fontWeight, FontWeight.bold);
    expect(
      find.descendant(of: check, matching: find.text('2')),
      findsOneWidget,
    );
  });

  group('the selected strip', () {
    Finder thumb(int index) =>
        find.byKey(ValueKey(('mpx-picker-viewer-strip', key(index))));

    Future<PickerHarness> openStrip(
      WidgetTester tester, {
      bool reorder = true,
    }) async {
      final h = PickerHarness();
      await h.pump(tester, viewerSlot: true, reorder: reorder);
      // Selected in the grid: the viewer has not shown them yet.
      for (final i in [5, 1, 7]) {
        h.selection.toggle(key(i));
      }
      await _open(tester, 1);
      await tester.tap(find.byKey(const ValueKey('mpx-picker-viewer-counter')));
      await PickerHarness.settle(tester);
      return h;
    }

    int shown(WidgetTester tester) =>
        tester.state<MediaViewerState>(find.byType(MediaViewer)).index;

    testWidgets('a tap shows that item, even one the viewer never showed', (
      tester,
    ) async {
      await openStrip(tester);
      expect(shown(tester), 1);
      await tester.tap(thumb(7));
      await PickerHarness.settle(tester);
      expect(shown(tester), 7);
    });

    testWidgets('the item shown is outlined', (tester) async {
      await openStrip(tester);
      BoxBorder? border(int index) =>
          (tester
                      .widget<DecoratedBox>(
                        find
                            .descendant(
                              of: thumb(index),
                              matching: find.byKey(
                                const ValueKey('mpx-picker-viewer-strip-frame'),
                              ),
                            )
                            .first,
                      )
                      .decoration
                  as BoxDecoration)
              .border;
      expect(border(1), isNotNull);
      expect(border(5), isNull);
    });

    testWidgets('a tap on its check deselects it', (tester) async {
      final h = await openStrip(tester);
      await tester.tapAt(tester.getTopRight(thumb(5)) + const Offset(-10, 10));
      await PickerHarness.settle(tester);
      expect(h.selection.keys, [key(1), key(7)]);
      expect(thumb(5), findsNothing);
    });

    testWidgets('a long press lifts an item and a drag moves it', (
      tester,
    ) async {
      final h = await openStrip(tester);
      final gesture = await tester.startGesture(tester.getCenter(thumb(5)));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await gesture.moveTo(tester.getCenter(thumb(7)));
      await tester.pump();
      await gesture.up();
      await PickerHarness.settle(tester);
      expect(h.selection.keys, [key(1), key(7), key(5)]);
    });
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
