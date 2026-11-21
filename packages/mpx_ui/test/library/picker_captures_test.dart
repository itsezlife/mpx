import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
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
}
