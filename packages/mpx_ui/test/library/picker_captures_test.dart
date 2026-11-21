import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_library/mpx_library.dart';
import 'package:mpx_library/testing.dart';
import 'package:mpx_ui/mpx_ui.dart';
import 'package:mpx_ui/testing.dart';

import 'library_picker_test.dart';

PickerCapture _capture(
  int n, {
  LibraryAssetKind kind = LibraryAssetKind.photo,
}) => PickerCapture(
  key: MediaKey$Local('00000000-0000-4000-8000-${'$n'.padLeft(12, '0')}'),
  kind: kind,
  dimensions: const MediaDimensions(1080, 1920),
  duration: kind == LibraryAssetKind.video ? const Duration(seconds: 7) : null,
  byteSize: 1000 + n,
);

Finder _cellOf(MediaKey key) => find.byKey(ValueKey<MediaKey>(key));

Future<void> _frames(WidgetTester tester, [int n = 20]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _close(WidgetTester tester) async {
  // Not awaited: the close runs as the test pumps frames.
  // ignore: unawaited_futures
  tester.state<MediaViewerState>(find.byType(MediaViewer)).close();
  await _frames(tester);
}

void main() {
  group('keys', () {
    test('a capture reads back as its own key; a library asset as the '
        'library key', () {
      final capture = _capture(1);
      expect(PickerCaptureKeys.isCapture(capture.asset), isTrue);
      expect(PickerCaptureKeys.keyOf(capture.asset), capture.key);
      expect(PickerCaptureKeys.thumbnailKeyOf(capture.asset, 100), capture.key);
      final library = FakeMediaLibrary.assetAt(0);
      expect(PickerCaptureKeys.isCapture(library), isFalse);
      expect(PickerCaptureKeys.keyOf(library), key(0));
    });

    test("a recording's thumbnail stands for it in cells; its key is still "
        "the recording's", () {
      final poster = MediaKey$Local('00000000-0000-4000-8000-0000000000aa');
      final video = PickerCapture(
        key: _capture(5).key,
        kind: LibraryAssetKind.video,
        thumbnail: poster,
      );
      expect(PickerCaptureKeys.keyOf(video.asset), video.key);
      expect(PickerCaptureKeys.thumbnailKeyOf(video.asset, 100), poster);
      final descriptor = PickerCaptureKeys.thumbnailDescriptorOf(
        video.asset,
        100,
      );
      expect(descriptor.key, poster);
      expect(descriptor.kind, MediaKind.still);
      expect(PickerCaptureKeys.descriptorOf(video.asset).kind, MediaKind.video);
    });

    test('a capture describes itself as what it is', () {
      final video = _capture(2, kind: LibraryAssetKind.video);
      final descriptor = PickerCaptureKeys.descriptorOf(video.asset);
      expect(descriptor.key, video.key);
      expect(descriptor.kind, MediaKind.video);
      expect(descriptor.duration, const Duration(seconds: 7));
      expect(
        PickerCaptureKeys.descriptorOf(_capture(3).asset).kind,
        MediaKind.still,
      );
    });
  });

  testWidgets('the gallery pages the captures, newest first, then the album', (
    tester,
  ) async {
    final library = FakeMediaLibrary(assets: 5);
    addTearDown(library.dispose);
    final album = (await library.albums()).first;
    final pages = LibraryPages(library: library, album: album);
    addTearDown(pages.dispose);
    final captures = ValueNotifier([_capture(1), _capture(2)]);
    addTearDown(captures.dispose);
    final source = LibraryGallerySource(pages, captures: captures);
    addTearDown(source.dispose);
    source.loadAround(2);
    await tester.pump();
    expect(source.count, 7);
    expect(source.captureCount, 2);
    expect(source.itemAt(0)!.key, _capture(2).key);
    expect(source.itemAt(1)!.key, _capture(1).key);
    expect(source.itemAt(2)!.key, key(0));
    expect(source.indexOf(_capture(1).key), 1);
    expect(source.indexOf(key(0)), 2);
    var told = 0;
    source.addListener(() => told++);
    captures.value = [...captures.value, _capture(3)];
    expect(told, 1);
    expect(source.itemAt(0)!.key, _capture(3).key);
    expect(source.indexOf(key(0)), 3);
  });

  testWidgets('captures sit first in the grid, newest first, with the cell, '
      'marks and selection number of a library item', (tester) async {
    final h = PickerHarness();
    final video = _capture(2, kind: LibraryAssetKind.video);
    final captures = ValueNotifier([_capture(1), video]);
    addTearDown(captures.dispose);
    await h.pump(tester, captures: captures, opensFirstCapture: false);
    final first = tester.getTopLeft(_cellOf(video.key));
    final second = tester.getTopLeft(_cellOf(_capture(1).key));
    final library = tester.getTopLeft(cell(0));
    expect(first.dy, second.dy);
    expect(first.dx, lessThan(second.dx));
    expect(second.dx, lessThan(library.dx));
    expect(
      find.descendant(
        of: _cellOf(video.key),
        matching: find.byKey(const ValueKey('mpx-mark-badge')),
      ),
      findsOneWidget,
      reason: "a video capture's duration badge",
    );
    h.selection
      ..toggle(key(0))
      ..toggle(video.key);
    await tester.pump();
    expect(
      find.descendant(of: _cellOf(video.key), matching: find.text('2')),
      findsOneWidget,
    );
    // The check takes the capture's own key.
    final corner =
        tester.getTopRight(_cellOf(_capture(1).key)) + const Offset(-12, 12);
    await tester.tapAt(corner);
    await tester.pump();
    expect(h.selection.keys, [key(0), video.key, _capture(1).key]);
    expectThemedText(tester);
  });

  testWidgets('the first capture opens the viewer on it, later ones do not; '
      'the viewer pages from the captures into the album', (tester) async {
    final h = PickerHarness();
    final captures = ValueNotifier(<PickerCapture>[]);
    addTearDown(captures.dispose);
    await h.pump(tester, captures: captures, viewerSlot: true);
    expect(find.byType(MediaViewer), findsNothing);
    captures.value = [_capture(1)];
    await _frames(tester);
    expect(find.byType(MediaViewer), findsOneWidget);
    expect(h.slotItems.last.index, 0);
    expect(h.slotItems.last.key, _capture(1).key);
    expectThemedText(tester);
    // The next page is the album's first item.
    await tester.fling(find.byType(MediaViewer), const Offset(-300, 0), 1000);
    await _frames(tester);
    expect(h.slotItems.last.index, 1);
    expect(h.slotItems.last.key, key(0));
    await _close(tester);
    captures.value = [...captures.value, _capture(2)];
    await _frames(tester);
    expect(find.byType(MediaViewer), findsNothing);
    expect(_cellOf(_capture(2).key), findsOneWidget);
  });

  testWidgets('the camera slot is told the viewer is open, so the host pauses '
      'the camera', (tester) async {
    final h = PickerHarness();
    final captures = ValueNotifier(<PickerCapture>[]);
    addTearDown(captures.dispose);
    await h.pump(tester, captures: captures, cameraSlot: true);
    captures.value = [_capture(1)];
    await _frames(tester);
    expect(find.byType(MediaViewer), findsOneWidget);
    expect(h.signals.last.viewerOpen, isTrue);
    await _close(tester);
    expect(h.signals.last.viewerOpen, isFalse);
  });

  test(r'$IOS opens the viewer on the 1st and every 10th capture, '
      r'$Android on the first only', () {
    expect(
      [
        for (var n = 1; n <= 21; n++)
          if (LibraryGridPolicy.$IOS.opensViewerOnCapture(n)) n,
      ],
      [1, 10, 20],
    );
    expect(
      [
        for (var n = 1; n <= 21; n++)
          if (LibraryGridPolicy.$Android.opensViewerOnCapture(n)) n,
      ],
      [1],
    );
  });

  testWidgets(r'with $IOS the 10th capture opens the viewer again', (
    tester,
  ) async {
    final h = PickerHarness();
    final captures = ValueNotifier(<PickerCapture>[]);
    addTearDown(captures.dispose);
    await h.pump(
      tester,
      captures: captures,
      viewerSlot: true,
      policy: LibraryGridPolicy.$IOS,
    );
    captures.value = [_capture(1)];
    await _frames(tester);
    expect(find.byType(MediaViewer), findsOneWidget);
    await _close(tester);
    for (var n = 2; n <= 9; n++) {
      captures.value = [...captures.value, _capture(n)];
      await _frames(tester, 2);
      expect(find.byType(MediaViewer), findsNothing, reason: '$n');
    }
    captures.value = [...captures.value, _capture(10)];
    await _frames(tester);
    expect(find.byType(MediaViewer), findsOneWidget);
    expect(h.slotItems.last.key, _capture(10).key);
    await _close(tester);
  });

  testWidgets('the host opens the viewer over the captures, a slot closes '
      'it, and the host hears it closed', (tester) async {
    final h = PickerHarness();
    final captures = ValueNotifier([_capture(1), _capture(2)]);
    addTearDown(captures.dispose);
    final picker = GlobalKey<LibraryPickerState>();
    var closed = 0;
    await h.pump(
      tester,
      captures: captures,
      viewerSlot: true,
      opensFirstCapture: false,
      pickerKey: picker,
      onViewerClosed: () => closed++,
    );
    picker.currentState!.openCaptures().ignore();
    await _frames(tester);
    expect(find.byType(MediaViewer), findsOneWidget);
    expect(h.slotItems.last.key, _capture(2).key);
    h.slotItems.last.close().ignore();
    await _frames(tester);
    expect(find.byType(MediaViewer), findsNothing);
    expect(closed, 1);
  });

  testWidgets('the viewer over the camera takes no dismiss drag, and closes '
      'by sliding the picture off downwards over 200 ms', (tester) async {
    final h = PickerHarness();
    final captures = ValueNotifier([_capture(1)]);
    addTearDown(captures.dispose);
    final picker = GlobalKey<LibraryPickerState>();
    await h.pump(
      tester,
      captures: captures,
      viewerSlot: true,
      opensFirstCapture: false,
      pickerKey: picker,
    );
    picker.currentState!.openCaptures().ignore();
    await _frames(tester);
    final viewer = find.byType(MediaViewer);
    final morph = find.byKey(const ValueKey('mpx-viewer-morph'));
    final drag = await tester.startGesture(tester.getCenter(viewer));
    for (var i = 0; i < 10; i++) {
      await drag.moveBy(const Offset(0, 40));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await drag.up();
    await _frames(tester);
    expect(viewer, findsOneWidget, reason: 'no dismiss drag');
    final rest = tester.getRect(find.byType(ViewerPhotoPage).first);
    tester.state<MediaViewerState>(viewer).close().ignore();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getRect(morph).top, greaterThan(rest.top + 100));
    expect(
      tester.getSize(morph).width,
      greaterThan(rest.width * 0.95),
      reason: 'it slides, it does not shrink',
    );
    await _frames(tester);
    expect(viewer, findsNothing);
  });

  testWidgets("the viewer's selected strip shows a recording by its "
      'thumbnail', (tester) async {
    final h = PickerHarness();
    final poster = MediaKey$Local('00000000-0000-4000-8000-0000000000bb');
    final video = PickerCapture(
      key: _capture(7).key,
      kind: LibraryAssetKind.video,
      duration: const Duration(seconds: 3),
      thumbnail: poster,
    );
    final captures = ValueNotifier([video]);
    addTearDown(captures.dispose);
    final picker = GlobalKey<LibraryPickerState>();
    await h.pump(
      tester,
      captures: captures,
      viewerSlot: true,
      opensFirstCapture: false,
      pickerKey: picker,
    );
    h.selection
      ..toggle(video.key)
      ..toggle(key(0));
    picker.currentState!.openCaptures().ignore();
    await _frames(tester);
    await tester.tap(find.byKey(const ValueKey('mpx-picker-viewer-counter')));
    await _frames(tester, 10);
    final item = find.byKey(
      ValueKey<(String, MediaKey)>(('mpx-picker-viewer-strip', video.key)),
    );
    expect(item, findsOneWidget);
    final shown = tester
        .widgetList<ContentView>(
          find.descendant(of: item, matching: find.byType(ContentView)),
        )
        .map((view) => view.content);
    expect(shown, [poster]);
  });

  testWidgets('the selection preview shows a recording by its thumbnail', (
    tester,
  ) async {
    final poster = MediaKey$Local('00000000-0000-4000-8000-0000000000cc');
    final video = PickerCapture(
      key: _capture(8).key,
      kind: LibraryAssetKind.video,
      thumbnail: poster,
    );
    final selection = OrderedPickerSelection()..toggle(video.key);
    addTearDown(selection.dispose);
    final clock = PlaybackClock(ticks: ManualPlaybackTickSource());
    final scope = AssetCacheScope(producer: FakeAssetProducer(), clock: clock);
    addTearDown(() {
      scope.dispose();
      clock.dispose();
    });
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: AssetCacheProvider(
          scope: scope,
          child: unthemedHost(
            PickerSelectionPreview(
              selection: selection,
              labels: gridLabels,
              onOpen: (_, _) {},
              assetOf: (key) => key == video.key ? video.asset : null,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final shown = tester
        .widgetList<ContentView>(find.byType(ContentView))
        .map((view) => view.content);
    expect(shown, [poster]);
  });
}
