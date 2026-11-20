import 'dart:ui' show CheckedState;

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
  late FakeMediaLibrary library;
  late LibraryAlbum album;
  late AssetCacheScope scope;
  late PlaybackClock clock;
  late OrderedPickerSelection selection;
  late List<(MediaKey, PickerRefusal)> refusals;
  late List<int> opened;

  setUp(() async {
    library = FakeMediaLibrary(assets: 10000);
    album = (await library.albums()).single;
    clock = PlaybackClock(ticks: ManualPlaybackTickSource());
    scope = AssetCacheScope(producer: FakeAssetProducer(), clock: clock);
    selection = OrderedPickerSelection();
    refusals = [];
    opened = [];
  });

  tearDown(() async {
    scope.dispose();
    clock.dispose();
    await library.dispose();
  });

  Future<void> pumpGrid(
    WidgetTester tester, {
    LibraryGridPolicy policy = LibraryGridPolicy.$Android,
    PickerSelection? picker,
    CameraSlotBuilder? camera,
    TextDirection direction = TextDirection.ltr,
    ScrollController? controller,
  }) async {
    tester.view
      ..physicalSize = const Size(390, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      Directionality(
        textDirection: direction,
        child: AssetCacheProvider(
          scope: scope,
          child: LibraryGrid(
            library: library,
            album: album,
            selection: picker ?? selection,
            labels: _labels,
            policy: policy,
            cameraSlotBuilder: camera,
            controller: controller,
            onRefused: (key, reason) => refusals.add((key, reason)),
            onOpen: (asset, index) => opened.add(index),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Finder cell(int index) => find.byKey(ValueKey(_key(index)));

  Future<void> tapCheck(WidgetTester tester, int index) async {
    final directional = Directionality.of(tester.element(cell(index)));
    final corner = directional == TextDirection.rtl
        ? tester.getTopLeft(cell(index)) + const Offset(12, 12)
        : tester.getTopRight(cell(index)) + const Offset(-12, 12);
    await tester.tapAt(corner);
    await tester.pump();
  }

  LibraryGridState state(WidgetTester tester) =>
      tester.state<LibraryGridState>(find.byType(LibraryGrid));

  testWidgets('over 10 000 assets only the pages near the viewport load', (
    tester,
  ) async {
    await pumpGrid(tester);
    expect(cell(0), findsOneWidget);
    final reads = state(tester).pages.pageReads;
    expect(reads, inInclusiveRange(1, 2));
    expect(cell(400), findsNothing);
    expect(state(tester).pages.total, 10000);
  });

  testWidgets('a check tap toggles and shows the order number', (tester) async {
    await pumpGrid(tester);
    await tapCheck(tester, 4);
    await tapCheck(tester, 1);
    expect(selection.keys, [_key(4), _key(1)]);
    expect(
      find.descendant(of: cell(1), matching: find.text('2')),
      findsOneWidget,
    );
    await tapCheck(tester, 4);
    expect(
      find.descendant(of: cell(1), matching: find.text('1')),
      findsOneWidget,
      reason: 're-numbered',
    );
  });

  testWidgets('a picture tap opens it', (tester) async {
    await pumpGrid(tester);
    await tester.tap(cell(2));
    expect(opened, [2]);
    expect(selection.keys, isEmpty);
  });

  testWidgets('refusals reach the host: the gate and the cap', (tester) async {
    final capped = OrderedPickerSelection(
      cap: 1,
      gate: (key) => key == _key(3) ? PickerRefusal.kind : null,
    );
    await pumpGrid(tester, picker: capped);
    await tapCheck(tester, 3);
    await tapCheck(tester, 0);
    await tapCheck(tester, 1);
    expect(capped.keys, [_key(0)]);
    expect(refusals, [
      (_key(3), PickerRefusal.kind),
      (_key(1), PickerRefusal.cap),
    ]);
    final dimmed = tester.widget<LibraryGridCell>(cell(1));
    expect(dimmed.dimmed, isTrue);
  });

  testWidgets(r'$Android swipe: long press, then drag over cells', (
    tester,
  ) async {
    await pumpGrid(tester);
    final gesture = await tester.startGesture(tester.getCenter(cell(0)));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
    await gesture.moveTo(tester.getCenter(cell(4)));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(selection.keys, [for (var i = 0; i <= 4; i++) _key(i)]);

    // Starting on a selected cell deselects every cell crossed.
    final back = await tester.startGesture(tester.getCenter(cell(1)));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
    await back.moveTo(tester.getCenter(cell(3)));
    await tester.pump();
    await back.up();
    await tester.pump();
    expect(selection.keys, [_key(0), _key(4)]);
  });

  testWidgets(r'$Android swipe: dragging back gives the cells left behind '
      'their state from before the drag', (tester) async {
    await pumpGrid(tester);
    await tapCheck(tester, 3);
    final gesture = await tester.startGesture(tester.getCenter(cell(0)));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
    await gesture.moveTo(tester.getCenter(cell(5)));
    await tester.pump();
    expect(selection.keys.toSet(), {for (var i = 0; i <= 5; i++) _key(i)});

    await gesture.moveTo(tester.getCenter(cell(2)));
    await tester.pump();
    expect(selection.keys, [_key(3), _key(0), _key(1), _key(2)]);

    // Back over the start: only the pressed cell keeps its new state.
    await gesture.moveTo(tester.getCenter(cell(0)));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(selection.keys, [_key(3), _key(0)]);
  });

  testWidgets(r'$Android swipe: a deselecting drag dragged back selects '
      'again what it had deselected', (tester) async {
    await pumpGrid(tester);
    for (var i = 0; i <= 4; i++) {
      await tapCheck(tester, i);
    }
    final gesture = await tester.startGesture(tester.getCenter(cell(1)));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
    await gesture.moveTo(tester.getCenter(cell(4)));
    await tester.pump();
    expect(selection.keys, [_key(0)]);
    await gesture.moveTo(tester.getCenter(cell(2)));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(selection.keys, [_key(0), _key(3), _key(4)]);
  });

  testWidgets(r'$IOS swipe: a horizontal pan selects', (tester) async {
    await pumpGrid(tester, policy: LibraryGridPolicy.$IOS);
    final start = tester.getCenter(cell(1));
    expect(start.dx, greaterThan(44));
    final gesture = await tester.startGesture(start);
    await gesture.moveBy(const Offset(10, 0));
    await tester.pump();
    await gesture.moveTo(tester.getCenter(cell(2)));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(selection.keys, [_key(1), _key(2)]);
  });

  testWidgets(r'$IOS swipe fails when it moves vertically first', (
    tester,
  ) async {
    await pumpGrid(tester, policy: LibraryGridPolicy.$IOS);
    final gesture = await tester.startGesture(tester.getCenter(cell(1)));
    await gesture.moveBy(const Offset(0, 6));
    await tester.pump();
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(selection.keys, isEmpty);
  });

  testWidgets(r'$IOS swipe does not start in the leading 44 points', (
    tester,
  ) async {
    await pumpGrid(tester, policy: LibraryGridPolicy.$IOS);
    final gesture = await tester.startGesture(
      tester.getTopLeft(cell(0)) + const Offset(20, 60),
    );
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(selection.keys, isEmpty);
  });

  testWidgets('library changes keep the selection', (tester) async {
    await pumpGrid(tester);
    await tapCheck(tester, 0);
    library.insert([
      const LibraryAsset(
        id: LibraryAssetId('fresh'),
        kind: LibraryAssetKind.photo,
      ),
    ]);
    await tester.pump();
    await tester.pump();
    expect(state(tester).pages.total, 10001);
    expect(selection.orderOf(_key(0)), 1);
    expect(
      find.descendant(of: cell(0), matching: find.text('1')),
      findsOneWidget,
    );
  });

  testWidgets('the camera slot holds the leading top and hears when it is '
      'off screen', (tester) async {
    final signals = <CameraSlotSignals>[];
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await pumpGrid(
      tester,
      controller: controller,
      camera: (context, value) {
        value.addListener(() => signals.add(value.value));
        return const SizedBox.expand(key: ValueKey('camera'));
      },
    );
    final slot = tester.getRect(find.byKey(const ValueKey('camera')));
    final first = tester.getRect(cell(0));
    expect(slot.left, lessThan(first.left));
    expect(slot.height, greaterThan(first.height * 2));
    controller.jumpTo(600);
    await tester.pump();
    expect(signals.last.onScreen, isFalse);
    expect(signals.last.shouldPause, isTrue);
  });

  testWidgets('right to left puts the check at the top end', (tester) async {
    await pumpGrid(tester, direction: TextDirection.rtl);
    await tapCheck(tester, 0);
    expect(selection.keys, [_key(0)]);
    expect(
      tester.getTopRight(cell(0)).dx,
      greaterThan(tester.getTopRight(cell(1)).dx),
      reason: 'the first cell is on the right',
    );
  });

  testWidgets('cells say kind, duration and selection', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpGrid(tester);
    await tapCheck(tester, 3);
    // Asset 3 is a video of 8 s.
    expect(find.bySemanticsLabel('Video, 0:08'), findsOneWidget);
    final check = tester.getSemantics(
      find.descendant(of: cell(3), matching: find.bySemanticsLabel('Select')),
    );
    expect(check.flagsCollection.isChecked, CheckedState.isTrue);
    expect(check.value, '1');
    handle.dispose();
  });
}
