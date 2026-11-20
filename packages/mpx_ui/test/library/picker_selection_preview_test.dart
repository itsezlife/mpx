import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_library/mpx_library.dart';
import 'package:mpx_library/testing.dart';
import 'package:mpx_ui/mpx_ui.dart';
import 'package:mpx_ui/testing.dart';

const _labels = LibraryGridLabels(
  photo: 'Photo',
  video: 'Video',
  open: 'Open',
  select: 'Select',
  gif: 'GIF',
);

MediaKey _key(int index) =>
    LibraryKeys.libraryKeyOf(FakeMediaLibrary.assetAt(index));

void main() {
  late FakeAssetProducer producer;
  late AssetCacheScope scope;
  late PlaybackClock clock;
  late OrderedPickerSelection selection;
  late List<(MediaKey, int)> opened;

  setUp(() {
    clock = PlaybackClock(ticks: ManualPlaybackTickSource());
    producer = FakeAssetProducer();
    scope = AssetCacheScope(producer: producer, clock: clock);
    selection = OrderedPickerSelection();
    for (final i in [4, 1, 7]) {
      selection.toggle(_key(i));
    }
    opened = [];
  });

  tearDown(() {
    scope.dispose();
    clock.dispose();
  });

  Future<void> pumpPreview(WidgetTester tester, {bool reorder = true}) async {
    tester.view
      ..physicalSize = const Size(390, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: AssetCacheProvider(
          scope: scope,
          child: unthemedHost(
            PickerSelectionPreview(
              selection: selection,
              labels: _labels,
              onOpen: (key, index) => opened.add((key, index)),
              onReorder: reorder ? selection.move : null,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expectThemedText(tester);
  }

  Finder cell(int index) => find.byKey(ValueKey(_key(index)));

  Finder orderIn(int index, String order) =>
      find.descendant(of: cell(index), matching: find.text(order));

  testWidgets('an order of three digits steps the number down', (tester) async {
    for (var i = 10; i < 107; i++) {
      selection.toggle(_key(i));
    }
    await pumpPreview(tester);
    await tester.drag(
      find.byType(PickerSelectionPreview),
      const Offset(0, -5000),
    );
    await tester.pumpAndSettle();
    final number = find.text('100');
    expect(number, findsOneWidget);
    expect(
      tester.widget<Text>(number).style!.fontSize,
      closeTo(13 * 10 / 14, 1e-9),
    );
    expectThemedText(tester);
  });

  testWidgets('a removed item fades out as the rest close the gap', (
    tester,
  ) async {
    await pumpPreview(tester);
    final firstSlot = tester.getTopLeft(cell(4));
    final secondSlot = tester.getTopLeft(cell(1));
    await tester.tapAt(tester.getTopRight(cell(4)) + const Offset(-12, 12));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // Half way: the item fades, the next one is between the two slots.
    expect(cell(4), findsOneWidget);
    final fading = tester
        .widgetList<Opacity>(
          find.ancestor(of: cell(4), matching: find.byType(Opacity)),
        )
        .map((o) => o.opacity)
        .reduce((a, b) => a * b);
    expect(fading, inExclusiveRange(0, 1));
    final moving = tester.getTopLeft(cell(1)).dx;
    expect(moving, inExclusiveRange(firstSlot.dx, secondSlot.dx));
    expectThemedText(tester);

    await tester.pump(const Duration(milliseconds: 150));
    expect(cell(4), findsNothing);
    expect(tester.getTopLeft(cell(1)), firstSlot);
  });

  testWidgets('a lifted item held near the bottom edge scrolls the list', (
    tester,
  ) async {
    for (var i = 20; i < 80; i++) {
      selection.toggle(_key(i));
    }
    await pumpPreview(tester);
    final list = tester.state<PickerSelectionPreviewState>(
      find.byType(PickerSelectionPreview),
    );
    expect(list.scrollOffset, 0);
    final gesture = await tester.startGesture(tester.getCenter(cell(4)));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await gesture.moveTo(const Offset(195, 795));
    await tester.pump();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 15));
    }
    expect(list.scrollOffset, greaterThan(40));
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('shows the selected items in their order', (tester) async {
    await pumpPreview(tester);
    expect(orderIn(4, '1'), findsOneWidget);
    expect(orderIn(1, '2'), findsOneWidget);
    expect(orderIn(7, '3'), findsOneWidget);
    expect(
      tester.getCenter(cell(4)).dx,
      lessThan(tester.getCenter(cell(1)).dx),
    );
  });

  testWidgets('each library item tells the cache its thumbnail, so its '
      'library key resolves', (tester) async {
    await pumpPreview(tester);
    final keys = producer.known.map((d) => d.key).toSet();
    final thumbnails = find.descendant(
      of: cell(4),
      matching: find.byType(ContentView),
    );
    final key = tester.widget<ContentView>(thumbnails).content;
    expect(keys, contains(key));
    expect(producer.attempts.map((a) => a.request.key), contains(key));
  });

  testWidgets('a tap on the order deselects; a tap on the picture opens', (
    tester,
  ) async {
    await pumpPreview(tester);
    await tester.tap(cell(7));
    expect(opened, [(_key(7), 2)]);

    await tester.tapAt(tester.getTopRight(cell(4)) + const Offset(-12, 12));
    await tester.pump();
    expect(selection.keys, [_key(1), _key(7)]);
    await tester.pump(const Duration(milliseconds: 250));
    expect(cell(4), findsNothing);
    expect(orderIn(1, '1'), findsOneWidget);
  });

  testWidgets('a long press lifts an item and dragging it over another '
      'moves it there', (tester) async {
    await pumpPreview(tester);
    final gesture = await tester.startGesture(tester.getCenter(cell(4)));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await gesture.moveTo(tester.getCenter(cell(7)));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(selection.keys, [_key(1), _key(7), _key(4)]);
  });

  testWidgets('without a reorder handler a long press moves nothing', (
    tester,
  ) async {
    await pumpPreview(tester, reorder: false);
    final gesture = await tester.startGesture(tester.getCenter(cell(4)));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await gesture.moveTo(tester.getCenter(cell(7)));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(selection.keys, [_key(4), _key(1), _key(7)]);
  });
}
