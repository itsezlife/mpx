import 'dart:ui' as ui;

import 'package:flutter/services.dart';
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
    expect(animated('Today'), findsOneWidget);
    expect(animated('1 of 3'), findsOneWidget);
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

    expect(animated('2/3'), findsOneWidget);
  });

  testWidgets('the counter is a pill as wide as its text, zoomed or not', (
    tester,
  ) async {
    final harness = ViewerHarness();
    await harness.pump(tester, chrome: chrome());
    final metrics = ViewerPolicy.$Android.chrome;
    final counter = find.byKey(const ValueKey('mpx-viewer-counter'));
    final text = tester.getSize(animated('1 of 3')).width;

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

  group('under the system bars', () {
    const top = 24.0;
    const bottom = 48.0;

    Future<ViewerHarness> open(WidgetTester tester) async {
      tester.view.padding = const FakeViewPadding(top: top, bottom: bottom);
      final harness = ViewerHarness();
      await harness.pump(tester, chrome: chrome());
      return harness;
    }

    testWidgets('a zoomed picture takes the whole screen, bars and all', (
      tester,
    ) async {
      final harness = await open(tester);
      await tester.tapAt(const Offset(200, 500));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(const Offset(200, 500));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // The page is the screen: the picture pans to its edges, under the
      // status and navigation bars, which are clear.
      expect(
        tester.getRect(find.byType(ViewerPhotoPage)),
        Offset.zero & viewerSize,
      );
      // At 3x the 300 px picture is 900 tall: 50 past each edge.
      expect(harness.page(tester).zoom, 3);
      await tester.drag(find.byType(ViewerPhotoPage), const Offset(0, -300));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(harness.page(tester).pan.dy, -50);
    });

    testWidgets('the system bars are clear with light icons; the viewer '
        'draws its own scrim over the navigation bar', (tester) async {
      await open(tester);
      final style = SystemChrome.latestStyle!;
      expect(style.statusBarColor, const Color(0x00000000));
      expect(style.statusBarIconBrightness, Brightness.light);
      expect(style.statusBarBrightness, Brightness.dark);
      expect(style.systemNavigationBarColor, const Color(0x00000000));
      expect(style.systemNavigationBarIconBrightness, Brightness.light);
      expect(style.systemNavigationBarContrastEnforced, isFalse);
      expect(style.systemStatusBarContrastEnforced, isFalse);

      final scrim = find.byKey(const ValueKey('mpx-viewer-navigation-scrim'));
      expect(
        tester.getRect(scrim),
        const Rect.fromLTWH(0, 800 - bottom, 400, bottom),
      );
      expect(
        tester.widget<ColoredBox>(scrim).color,
        const ViewerTokens().barFill,
      );
    });
  });

  testWidgets('a single item has no counter', (tester) async {
    final harness = ViewerHarness(count: 1);
    await harness.pump(tester, chrome: chrome());

    expect(find.byKey(const ValueKey('mpx-viewer-counter')), findsNothing);
  });

  testWidgets('the chrome fades in with the morph, not after it', (
    tester,
  ) async {
    final harness = ViewerHarness();
    await harness.pump(tester, chrome: chrome(), open: false);

    final top = find.byKey(const ValueKey('mpx-viewer-top'));
    double opacity() => tester
        .widgetList<Opacity>(
          find.ancestor(of: top, matching: find.byType(Opacity)),
        )
        .fold(1, (value, widget) => value * widget.opacity);

    // At the first frame the morph has not moved: nothing shows yet.
    expect(opacity(), 0);

    await tester.pump(const Duration(milliseconds: 100));
    final halfway = opacity();
    expect(halfway, inExclusiveRange(0.2, 0.8));

    await tester.pump(const Duration(milliseconds: 150));
    expect(opacity(), 1);
    expect(halfway, lessThan(opacity()));
  });

  testWidgets('a part of the chrome that the next item shares does not '
      'animate, one it changes does', (tester) async {
    final harness = ViewerHarness();
    await harness.pump(
      tester,
      chrome: ViewerChrome(
        title: (context, index, item) => const Text('Same author'),
        subtitle: (context, index, item) => Text('Day $index'),
      ),
    );

    await tester.fling(
      find.byType(ViewerPhotoPage),
      const Offset(-300, 0),
      1000,
    );
    await tester.pump();
    // The page settles and the item changes at its end; the change begins.
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 60));

    // The title is one text all through; the subtitle has two, one leaving.
    expect(find.text('Same author'), findsOneWidget);
    // The date line is a text that swaps what changed: its width is between
    // the two while it does, and it says the new one.
    expect(animated('Day 1'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(animated('Day 0'), findsNothing);
  });

  testWidgets('a tap on the picture hides and shows the chrome', (
    tester,
  ) async {
    final harness = ViewerHarness();
    await harness.pump(tester, chrome: chrome());

    await tapPicture(tester);
    expect(harness.state(tester).controlsVisible, isFalse);
    // The nearest: the chrome's own, under the morph's.
    final top = tester.widget<Opacity>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('mpx-viewer-top')),
            matching: find.byType(Opacity),
          )
          .first,
    );
    expect(top.opacity, 0);

    await tapPicture(tester);
    expect(harness.state(tester).controlsVisible, isTrue);
  });

  group('system bars', () {
    late List<Object?> modes;

    setUp(() {
      modes = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            switch (call.method) {
              case 'SystemChrome.setEnabledSystemUIMode':
              case 'SystemChrome.setEnabledSystemUIOverlays':
                modes.add(call.arguments);
            }
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    // Only the status bar goes with the controls: the navigation bar is
    // clear and the pictures lie above it, so there is nothing to win by
    // hiding it, and it would bring the gesture area up over the picture.
    const statusBarGone = ['SystemUiOverlay.bottom'];
    const back = 'SystemUiMode.edgeToEdge';

    testWidgets('the status bar goes with the controls and comes back', (
      tester,
    ) async {
      final harness = ViewerHarness();
      await harness.pump(tester, chrome: chrome());
      modes.clear();

      await tapPicture(tester);
      expect(modes, [statusBarGone]);

      await tapPicture(tester);
      expect(modes, [statusBarGone, back]);
    });

    testWidgets('both bars go under hideAll', (tester) async {
      final harness = ViewerHarness(systemBars: ViewerSystemBars.hideAll);
      await harness.pump(tester, chrome: chrome());
      modes.clear();

      await tapPicture(tester);
      expect(modes, ['SystemUiMode.immersiveSticky']);
    });

    testWidgets('none goes under keep', (tester) async {
      final harness = ViewerHarness(systemBars: ViewerSystemBars.keep);
      await harness.pump(tester, chrome: chrome());
      modes.clear();

      await tapPicture(tester);
      await tapPicture(tester);
      expect(modes, isEmpty);
    });

    testWidgets('are shown again when the viewer closes with them hidden', (
      tester,
    ) async {
      final harness = ViewerHarness();
      await harness.pump(tester, chrome: chrome());
      modes.clear();
      await tapPicture(tester);

      final closing = harness.state(tester).close();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 201));
      await closing;

      expect(modes.last, back);
    });
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

  group('the caption', () {
    final sheet = find.byType(ViewerCaptionSheet);
    final text = find.descendant(of: sheet, matching: find.byType(Text));
    // Five lines of 16 px type at 1.2 plus 8 px above and below.
    const five = 16 * 1.2 * 5 + 16;
    const padding = 8.0;

    // The box behind the text: from where the text starts (8 px above it) to
    // the foot of the room, never above the room.
    Rect box(WidgetTester tester) {
      final room = tester.getRect(sheet);
      final top = (tester.getTopLeft(text).dy - padding).clamp(
        room.top,
        room.bottom,
      );
      return Rect.fromLTRB(room.left, top, room.right, room.bottom);
    }

    // A point on the box, where the touches are the caption's.
    Offset onBox(WidgetTester tester) => Offset(200, box(tester).top + 30);

    String lines(int count) => List.filled(count, 'line').join('\n');

    testWidgets('starts at five lines, however long it is', (tester) async {
      final harness = ViewerHarness();
      await harness.pump(tester, chrome: chrome(caption: lines(40)));

      expect(box(tester).height, closeTo(five, 0.01));
    });

    testWidgets('is as tall as its text when that is short', (tester) async {
      final harness = ViewerHarness();
      await harness.pump(tester, chrome: chrome(caption: 'one line'));

      // One line and its padding, not the five a long one starts at.
      expect(box(tester).height, inExclusiveRange(16 + 16, 16 + 16 * 2));
    });

    testWidgets('a drag up takes it over the picture, then scrolls the text', (
      tester,
    ) async {
      final harness = ViewerHarness();
      await harness.pump(tester, chrome: chrome(caption: lines(40)));
      final collapsed = box(tester);

      await tester.dragFrom(onBox(tester), const Offset(0, -150));
      await tester.pump();

      final grown = box(tester);
      expect(grown.height, greaterThan(collapsed.height + 100));
      // It grows upward: its foot stays where it was.
      expect(grown.bottom, collapsed.bottom);

      // Never past the top bar: the picture's top part stays.
      await tester.dragFrom(onBox(tester), const Offset(0, -2000));
      await tester.pump(const Duration(seconds: 1));
      final top = tester.getRect(find.byKey(const ValueKey('mpx-viewer-top')));
      expect(box(tester).top, greaterThanOrEqualTo(top.bottom));
    });

    testWidgets('the picture above it takes the touches', (tester) async {
      final harness = ViewerHarness();
      await harness.pump(tester, chrome: chrome(caption: lines(40)));

      // A tap over the picture, above the box, still hides the chrome.
      await tapPicture(tester);
      expect(harness.state(tester).controlsVisible, isFalse);
    });

    testWidgets('fades at its edges while there is more text', (tester) async {
      final harness = ViewerHarness();
      await harness.pump(tester, chrome: chrome(caption: lines(40)));

      expect(
        find.descendant(of: sheet, matching: find.byType(ShaderMask)),
        findsOneWidget,
      );
    });

    testWidgets('gives under a pull past its end and settles back', (
      tester,
    ) async {
      final harness = ViewerHarness();
      await harness.pump(tester, chrome: chrome(caption: lines(40)));
      await tester.dragFrom(onBox(tester), const Offset(0, -3000));
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      final rest = tester.getTopLeft(text).dy;

      final gesture = await tester.startGesture(onBox(tester));
      // The first move is the slop; the drag is what follows it.
      await gesture.moveBy(const Offset(0, -20));
      await gesture.moveBy(const Offset(0, -80));
      await tester.pump();

      // Past the end: the text gave.
      expect(rest - tester.getTopLeft(text).dy, greaterThan(5));

      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(tester.getTopLeft(text).dy, closeTo(rest, 0.5));
    });

    testWidgets('resists a long pull more the further it goes, as usual', (
      tester,
    ) async {
      final harness = ViewerHarness();
      await harness.pump(tester, chrome: chrome(caption: lines(40)));
      await tester.dragFrom(onBox(tester), const Offset(0, -3000));
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      final rest = tester.getTopLeft(text).dy;

      final gesture = await tester.startGesture(onBox(tester));
      await gesture.moveBy(const Offset(0, -20));
      // The text follows by the share of its room not yet given: of a pull
      // of 400 px, the room being 600 px, it goes 600 * (1 - e^(-400 / 600)).
      for (var i = 0; i < 8; i++) {
        await gesture.moveBy(const Offset(0, -50));
      }
      await tester.pump();

      final given = rest - tester.getTopLeft(text).dy;
      expect(given, inExclusiveRange(250, 330));
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('gives under a pull past its start too', (tester) async {
      final harness = ViewerHarness();
      await harness.pump(tester, chrome: chrome(caption: lines(40)));
      final rest = tester.getTopLeft(text).dy;

      final gesture = await tester.startGesture(onBox(tester));
      await gesture.moveBy(const Offset(0, 20));
      await gesture.moveBy(const Offset(0, 80));
      await tester.pump();

      expect(tester.getTopLeft(text).dy - rest, greaterThan(5));
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(tester.getTopLeft(text).dy, closeTo(rest, 0.5));
    });

    testWidgets(
      'a text that all shows gives under a pull too, as usual, and settles back',
      (tester) async {
        final harness = ViewerHarness();
        // Under five lines: the box is as tall as the text, nothing is left to
        // scroll, and the feel is the same.
        await harness.pump(tester, chrome: chrome(caption: lines(3)));
        final rest = tester.getTopLeft(text).dy;
        final boxHeight = box(tester).height;

        for (final dy in [-80.0, 80.0]) {
          final gesture = await tester.startGesture(onBox(tester));
          await gesture.moveBy(Offset(0, dy.sign * 20));
          await gesture.moveBy(Offset(0, dy));
          await tester.pump();
          expect((tester.getTopLeft(text).dy - rest).abs(), greaterThan(5));

          await gesture.up();
          await tester.pump();
          await tester.pump(const Duration(seconds: 3));
          expect(tester.getTopLeft(text).dy, closeTo(rest, 0.5));
          expect(box(tester).height, closeTo(boxHeight, 0.5));
        }
      },
    );
  });

  testWidgets('a thumbnail moves the viewer to its item', (tester) async {
    final harness = ViewerHarness();
    await harness.pump(tester, chrome: chrome(thumbnails: true));

    expect(find.byKey(const ValueKey('mpx-viewer-strip')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey(('mpx-viewer-thumb', 2))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(harness.state(tester).index, 2);
    expect(animated('3 of 3'), findsOneWidget);
  });
}

/// The animated text that says [text] (the date line, the counter).
Finder animated(String text) => find.byWidgetPredicate(
  (widget) => widget is ViewerAnimatedText && widget.text == text,
);

String _counter(int position, int count) => '$position/$count';
