import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_library/mpx_library.dart';
import 'package:mpx_library/testing.dart';
import 'package:mpx_ui/mpx_ui.dart';

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
          child: PickerSelectionPreview(
            selection: selection,
            labels: _labels,
            onOpen: (key, index) => opened.add((key, index)),
            onReorder: reorder ? selection.move : null,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Finder cell(int index) => find.byKey(ValueKey(_key(index)));

  Finder orderIn(int index, String order) =>
      find.descendant(of: cell(index), matching: find.text(order));

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
