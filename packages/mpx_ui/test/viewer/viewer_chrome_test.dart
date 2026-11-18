import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_ui/mpx_ui.dart';
import 'package:mpx_ui/testing.dart';

import 'viewer_harness.dart';

void main() {
  late List<ViewerActionRequest> saved;
  late List<ViewerActionRequest> shared;
  late List<FakeViewerFile> files;

  setUp(() {
    saved = [];
    shared = [];
    files = [];
  });

  ViewerChrome chrome({String? caption, bool thumbnails = false}) =>
      ViewerChrome(
        title: (context, index, item) => Text('Author $index'),
        subtitle: (context, index, item) => const Text('Today'),
        caption: caption == null
            ? null
            : (context, index, item) => Text(caption),
        thumbnails: thumbnails,
        openFile: (key) async {
          final file = FakeViewerFile('/cache/${key.encoded}');
          files.add(file);
          return file;
        },
        actions: (index, item) => [
          ViewerAction(
            label: 'Share',
            icon: const SizedBox.square(dimension: 24),
            inBar: true,
            onSelected: shared.add,
          ),
          ViewerAction(
            label: 'Save',
            onSelected: (request) async {
              saved.add(request);
              await request.file();
            },
          ),
          ViewerAction(label: 'Show in list', onSelected: (_) {}),
        ],
      );

  Future<void> tapPicture(WidgetTester tester) async {
    await tester.tapAt(const Offset(200, 400));
    // A single tap waits out the double-tap window.
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pump(const Duration(milliseconds: 201));
  }

  testWidgets('the bars show the title, subtitle and counter on open', (
    tester,
  ) async {
    final harness = ViewerHarness();
    await harness.pump(tester, chrome: chrome());

    expect(find.text('Author 0'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('1 of 3'), findsOneWidget);
    expect(harness.state(tester).controlsVisible, isTrue);
  });

  testWidgets('the counter follows the page and uses the host strings', (
    tester,
  ) async {
    final harness = ViewerHarness();
    await harness.pump(
      tester,
      chrome: const ViewerChrome(strings: ViewerStrings(counter: _counter)),
    );

    await tester.fling(
      find.byType(ViewerPhotoPage),
      const Offset(-300, 0),
      1000,
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('2/3'), findsOneWidget);
  });

  testWidgets('the counter is a pill as wide as its text, zoomed or not', (
    tester,
  ) async {
    final harness = ViewerHarness();
    await harness.pump(tester, chrome: chrome());
    final metrics = ViewerPolicy.$Android.chrome;
    final counter = find.byKey(const ValueKey('mpx-viewer-counter'));
    final text = tester.getSize(find.text('1 of 3')).width;

    void expectPill() {
      final rect = tester.getRect(counter);
      expect(rect.width, closeTo(text + 2 * metrics.counterPadding, 1));
      expect(rect.height, metrics.counterHeight);
      expect(rect.center.dx, closeTo(viewerSize.width / 2, 0.5));
    }

    expectPill();

    // Double tap away from the chrome: the picture zooms under it.
    await tester.tapAt(const Offset(200, 500));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(const Offset(200, 500));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(harness.page(tester).isZoomed, isTrue);
    expectPill();
  });

  testWidgets('a single item has no counter', (tester) async {
    final harness = ViewerHarness(count: 1);
    await harness.pump(tester, chrome: chrome());

    expect(find.byKey(const ValueKey('mpx-viewer-counter')), findsNothing);
  });

  testWidgets('a tap on the picture hides and shows the chrome', (
    tester,
  ) async {
    final harness = ViewerHarness();
    await harness.pump(tester, chrome: chrome());

    await tapPicture(tester);
    expect(harness.state(tester).controlsVisible, isFalse);
    final top = tester.widget<Opacity>(
      find.ancestor(
        of: find.byKey(const ValueKey('mpx-viewer-top')),
        matching: find.byType(Opacity),
      ),
    );
    expect(top.opacity, 0);

    await tapPicture(tester);
    expect(harness.state(tester).controlsVisible, isTrue);
  });

  testWidgets('a dismiss drag hides the chrome', (tester) async {
    final harness = ViewerHarness();
    await harness.pump(tester, chrome: chrome());

    final gesture = await tester.startGesture(const Offset(200, 400));
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();

    expect(harness.state(tester).controlsVisible, isFalse);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('back closes the viewer', (tester) async {
    final harness = ViewerHarness();
    await harness.pump(tester, chrome: chrome());

    await tester.tap(find.byKey(const ValueKey('mpx-viewer-back')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 201));

    expect(harness.closed, 1);
  });

  testWidgets('a bar action runs with the item', (tester) async {
    final harness = ViewerHarness();
    await harness.pump(tester, chrome: chrome());

    await tester.tap(find.bySemanticsLabel('Share'));
    await tester.pump();

    expect(shared.single.index, 0);
    expect(shared.single.item.key, photoKey(0));
  });

  testWidgets('menu actions get the cached file, released when done', (
    tester,
  ) async {
    final harness = ViewerHarness();
    await harness.pump(tester, chrome: chrome());

    await tester.tap(find.byKey(const ValueKey('mpx-viewer-more')));
    await tester.pump();
    expect(find.text('Save'), findsOneWidget);
    expect(find.text('Show in list'), findsOneWidget);
    // The bar action is not repeated in the menu.
    expect(find.text('Share'), findsNothing);

    await tester.tap(find.text('Save'));
    await tester.pump();

    expect(find.byKey(const ValueKey('mpx-viewer-menu')), findsNothing);
    expect(saved.single.item.key, photoKey(0));
    expect(files.single.path, '/cache/${photoKey(0).encoded}');
    expect(files.single.isReleased, isTrue);
  });

  testWidgets('a file opened after the action ended is released at once', (
    tester,
  ) async {
    final harness = ViewerHarness();
    late ViewerActionRequest kept;
    await harness.pump(
      tester,
      chrome: ViewerChrome(
        openFile: (key) async => FakeViewerFile('/late'),
        actions: (index, item) => [
          ViewerAction(label: 'Keep', onSelected: (request) => kept = request),
        ],
      ),
    );
    await tester.tap(find.byKey(const ValueKey('mpx-viewer-more')));
    await tester.pump();
    await tester.tap(find.text('Keep'));
    await tester.pump();

    expect(await kept.file(), isNull);
  });

  testWidgets('an action gets the picture as it shows', (tester) async {
    final harness = ViewerHarness();
    ui.Image? frame;
    await harness.pump(
      tester,
      chrome: ViewerChrome(
        actions: (index, item) => [
          ViewerAction(
            label: 'Frame',
            onSelected: (request) async => frame = await request.frame(),
          ),
        ],
      ),
    );

    await tester.runAsync(
      () => harness
          .state(tester)
          .runAction(
            ViewerAction(
              label: 'Frame',
              onSelected: (request) async => frame = await request.frame(),
            ),
            0,
          ),
    );

    expect(frame, isNotNull);
    expect(frame!.width, 400);
    expect(frame!.height, 300);
    frame!.dispose();
  });

  testWidgets('the caption shows up to five lines, then scrolls', (
    tester,
  ) async {
    final harness = ViewerHarness();
    await harness.pump(
      tester,
      chrome: chrome(caption: List.filled(40, 'line').join('\n')),
    );

    final box = tester.getSize(
      find.byKey(const ValueKey('mpx-viewer-caption')),
    );
    // Five lines of 16 px type at 1.2 plus 8 px above and below.
    expect(box.height, closeTo(16 * 1.2 * 5 + 16, 0.01));
  });

  testWidgets('a thumbnail moves the viewer to its item', (tester) async {
    final harness = ViewerHarness();
    await harness.pump(tester, chrome: chrome(thumbnails: true));

    expect(find.byKey(const ValueKey('mpx-viewer-strip')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey(('mpx-viewer-thumb', 2))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(harness.state(tester).index, 2);
    expect(find.text('3 of 3'), findsOneWidget);
  });
}

String _counter(int position, int count) => '$position/$count';
