import 'dart:math' as math;

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
    // Let go short of the close: it springs back and the chrome fades in
    // with it.
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(chromeOpacity(), inExclusiveRange(0, 1));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(MediaViewer), findsOneWidget);
    expect(chromeOpacity(), 1);
    expectThemedText(tester);
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

  testWidgets('the top bar: back, the host title, and the count and the '
      'check on its line at the end', (tester) async {
    final h = PickerHarness();
    await h.pump(tester, viewerSlot: true, viewerTitle: 'Saved Messages');
    h.selection
      ..toggle(key(0))
      ..toggle(key(2));
    await _open(tester, 2);
    final bar = find.byKey(const ValueKey('mpx-picker-viewer-bar'));
    final check = find.byKey(const ValueKey('mpx-picker-viewer-check-mark'));
    final counter = find.byKey(const ValueKey('mpx-picker-viewer-counter'));
    const width = 390.0;
    expect(tester.getRect(bar), const Rect.fromLTWH(0, 0, width, 56));
    expect(
      find.descendant(of: bar, matching: find.text('Saved Messages')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('mpx-picker-viewer-back')),
      findsOneWidget,
    );
    // A photo has no info line.
    expect(
      find.byKey(const ValueKey('mpx-picker-viewer-subtitle')),
      findsNothing,
    );
    expect(tester.getSize(check), const Size.square(34));
    expect(tester.getCenter(check).dy, 28);
    expect(tester.getRect(check).right, width - 11);
    final pill = tester.getRect(counter);
    expect(pill.right, width - 64);
    expect(pill.height, 28);
    expect(pill.center.dy, 28);
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

    // The strip opens below the bar.
    await tester.tap(counter);
    await PickerHarness.settle(tester);
    expect(
      tester.getTopLeft(find.byType(ListView).last).dy,
      greaterThanOrEqualTo(56),
    );

    // Back closes the viewer.
    await tester.tap(find.byKey(const ValueKey('mpx-picker-viewer-back')));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byType(MediaViewer), findsNothing);
  });

  testWidgets('a video has its info line: size, duration and ~bytes', (
    tester,
  ) async {
    final h = PickerHarness();
    await h.pump(tester, viewerSlot: true);
    // The fourth fake asset is a 1920x1080 video of 8 s, 2 400 003 bytes.
    await _open(tester, 3);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('mpx-picker-viewer-subtitle')),
        matching: find.text('1920x1080, 0:08, ~2.3 MB'),
      ),
      findsOneWidget,
    );
    expect(h.selection.keys, isEmpty);
  });

  group('the info line', () {
    Finder subtitle() =>
        find.byKey(const ValueKey('mpx-picker-viewer-subtitle'));
    final title = find.text('Chat');

    double lineOpacity(WidgetTester tester, String text) => tester
        .widgetList<Opacity>(
          find.ancestor(
            of: find.descendant(of: subtitle(), matching: find.text(text)),
            matching: find.byType(Opacity),
          ),
        )
        .map((o) => o.opacity)
        .reduce((a, b) => a * b);

    double titleScale(WidgetTester tester) => tester
        .widgetList<Transform>(
          find.ancestor(of: title, matching: find.byType(Transform)),
        )
        .map((t) => t.transform.storage[0])
        .reduce((a, b) => a * b);

    testWidgets('Android: paging to a video, the line fades in as the title '
        'rises and shrinks', (tester) async {
      final h = PickerHarness();
      await h.pump(tester, viewerSlot: true, viewerTitle: 'Chat');
      await _open(tester, 2);
      expect(subtitle(), findsNothing);
      expect(titleScale(tester), 1);

      await tester.fling(find.byType(MediaViewer), const Offset(-300, 0), 2000);
      for (var i = 0; i < 60 && subtitle().evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      const text = '1920x1080, 0:08, ~2.3 MB';
      await tester.pump(const Duration(milliseconds: 60));
      expect(lineOpacity(tester, text), inExclusiveRange(0, 1));
      expect(titleScale(tester), inExclusiveRange(0.87, 1));
      expectThemedText(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(lineOpacity(tester, text), 1);
      expect(titleScale(tester), closeTo(0.87, 1e-6));
    });

    testWidgets('Android: a new line replaces the old one, the old going out '
        'as the new comes in', (tester) async {
      final h = PickerHarness();
      await h.pump(tester, viewerSlot: true, viewerTitle: 'Chat');
      h.selection.toggle(key(7));
      await _open(tester, 3);
      const before = '1920x1080, 0:08, ~2.3 MB';
      const after = '1920x1080, 0:12, ~2.3 MB';
      expect(lineOpacity(tester, before), 1);
      await tester.tap(find.byKey(const ValueKey('mpx-picker-viewer-counter')));
      await PickerHarness.settle(tester);
      await tester.tap(
        find.byKey(ValueKey(('mpx-picker-viewer-strip', key(7)))),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(lineOpacity(tester, before), inExclusiveRange(0, 1));
      expect(lineOpacity(tester, after), inExclusiveRange(0, 1));
      expectThemedText(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.descendant(of: subtitle(), matching: find.text(before)),
        findsNothing,
      );
      expect(lineOpacity(tester, after), 1);
    });

    testWidgets('Android: paging away from a video and back brings its '
        'line back', (tester) async {
      final h = PickerHarness();
      await h.pump(tester, viewerSlot: true, viewerTitle: 'Chat');
      await _open(tester, 3);
      const text = '1920x1080, 0:08, ~2.3 MB';
      expect(lineOpacity(tester, text), 1);
      Future<void> page(double dx) async {
        await tester.fling(find.byType(MediaViewer), Offset(dx, 0), 2000);
        for (var i = 0; i < 40; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        await tester.pump(const Duration(milliseconds: 400));
      }

      await page(-300);
      expect(tester.state<MediaViewerState>(find.byType(MediaViewer)).index, 4);
      expect(lineOpacity(tester, text), 0, reason: 'gone with the photo');
      await page(300);
      expect(tester.state<MediaViewerState>(find.byType(MediaViewer)).index, 3);
      expect(lineOpacity(tester, text), 1);
      expect(titleScale(tester), closeTo(0.87, 1e-6));
      expectThemedText(tester);
    });

    testWidgets('iOS: no info line', (tester) async {
      final h = PickerHarness();
      await h.pump(
        tester,
        viewerSlot: true,
        viewerTitle: 'Chat',
        policy: LibraryGridPolicy.$IOS,
      );
      await _open(tester, 3);
      expect(subtitle(), findsNothing);
      expect(title, findsOneWidget);
    });
  });

  group('chrome lifecycle', () {
    final check = find.byKey(const ValueKey('mpx-picker-viewer-check'));
    double opacity(WidgetTester tester) => tester
        .widgetList<FadeTransition>(
          find.ancestor(of: check, matching: find.byType(FadeTransition)),
        )
        .map((f) => f.opacity.value)
        .reduce((a, b) => a * b);

    testWidgets('fades in with the open animation', (tester) async {
      final h = PickerHarness();
      await h.pump(tester, viewerSlot: true);
      await tester.tap(cell(2));
      await tester.pump();
      await tester.pump();
      expect(opacity(tester), lessThan(1));
      await tester.pump(const Duration(milliseconds: 100));
      expect(opacity(tester), inExclusiveRange(0, 1));
      await tester.pump(const Duration(milliseconds: 250));
      expect(opacity(tester), 1);
      expectThemedText(tester);
    });

    testWidgets('it never hides by itself', (tester) async {
      final h = PickerHarness();
      await h.pump(tester, viewerSlot: true);
      await _open(tester, 2);
      final viewer = tester.widget<MediaViewer>(find.byType(MediaViewer));
      expect(viewer.policy!.video.autoHides, isFalse);
      expect(viewer.policy!.video.clickPlays, isTrue);
      expect(viewer.policy!.video.centreWhilePlaying, isFalse);
      await tester.pump(const Duration(seconds: 5));
      expect(opacity(tester), 1);
    });

    testWidgets('a tap on a photo selects it, again deselects it; the chrome '
        'stays', (tester) async {
      final h = PickerHarness();
      await h.pump(tester, viewerSlot: true);
      await _open(tester, 2);
      Future<void> tap() async {
        await tester.tapAt(const Offset(195, 400));
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
      }

      await tap();
      expect(h.selection.keys, [key(2)]);
      expect(opacity(tester), 1);
      await tap();
      expect(h.selection.keys, isEmpty);
      expect(opacity(tester), 1);
      expectThemedText(tester);
    });

    testWidgets('a tap on a video with no player neither selects it nor '
        'hides the chrome', (tester) async {
      final h = PickerHarness();
      await h.pump(tester, viewerSlot: true);
      await _open(tester, 3);
      await tester.tapAt(const Offset(195, 400));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(h.selection.keys, isEmpty);
      expect(opacity(tester), 1);
    });
  });

  testWidgets('the top bar has no band: a scrim from the top of the screen '
      'under the status bar fades to clear', (tester) async {
    final h = PickerHarness();
    await h.pump(tester, viewerSlot: true, top: 24);
    await _open(tester, 2);
    final bar = find.byKey(const ValueKey('mpx-picker-viewer-bar'));
    expect(tester.getRect(bar).top, 24);
    expect(
      find.descendant(of: bar, matching: find.byType(ColoredBox)),
      findsNothing,
    );
    final scrim = find.byKey(const ValueKey('mpx-picker-viewer-top-scrim'));
    // 1.5 status bars and the bar.
    expect(tester.getRect(scrim), const Rect.fromLTWH(0, 0, 390, 92));
    final gradient =
        (tester.widget<DecoratedBox>(scrim).decoration as BoxDecoration)
                .gradient!
            as LinearGradient;
    expect(gradient.colors.first, const Color(0xD0000000));
    expect(gradient.colors.last.a, 0);
  });

  testWidgets("the host's bottom bar sits at the bottom, the viewer's "
      'controls above it, and the keyboard lifts both', (tester) async {
    final h = PickerHarness();
    await h.pump(tester, viewerSlot: true);
    await _open(tester, 2);
    final slot = find.byKey(const ValueKey('slot'));
    expect(tester.getRect(slot).bottom, 800);
    double viewerBottom() =>
        MediaQuery.paddingOf(tester.element(find.byType(MediaViewer))).bottom;
    expect(viewerBottom(), 60);
  });

  testWidgets('the keyboard lifts the bottom bar and the controls above it', (
    tester,
  ) async {
    final h = PickerHarness();
    await h.pump(tester, viewerSlot: true, keyboard: 300);
    await _open(tester, 2);
    final slot = find.byKey(const ValueKey('slot'));
    double viewerBottom() =>
        MediaQuery.paddingOf(tester.element(find.byType(MediaViewer))).bottom;
    expect(tester.getRect(slot).bottom, 500);
    expect(viewerBottom(), 360);
  });

  for (final (name, stripped) in [
    ('the padding the inset leaves', false),
    ('a host that stripped the padding', true),
  ]) {
    testWidgets('as the keyboard hides frame by frame, the bottom bar never '
        'goes below its rest place: $name', (tester) async {
      final h = PickerHarness();
      await h.pump(tester, viewerSlot: true);
      await _open(tester, 2);
      final slot = find.byKey(const ValueKey('slot'));
      const safe = 48.0;
      MediaQueryData frame(double inset) => MediaQueryData(
        size: const Size(390, 800),
        viewInsets: EdgeInsets.only(bottom: inset),
        viewPadding: const EdgeInsets.only(bottom: safe),
        padding: EdgeInsets.only(
          bottom: stripped ? 0 : math.max(0, safe - inset),
        ),
      );
      for (var inset = 358.0; inset >= 0; inset -= 2) {
        h.media.value = frame(inset);
        await tester.pump(const Duration(milliseconds: 16));
        final bottom = tester.getRect(slot).bottom;
        expect(
          bottom,
          closeTo(800 - math.max(inset, safe), 1e-6),
          reason: 'at an inset of $inset',
        );
      }
      expectThemedText(tester);
    });
  }

  testWidgets('a slot that holds the keyboard itself stays at the bottom '
      'edge as the keyboard shows and hides; the controls stay above it', (
    tester,
  ) async {
    final h = PickerHarness();
    await h.pump(tester, viewerSlot: true, slotHoldsKeyboard: true);
    await _open(tester, 2);
    final slot = find.byKey(const ValueKey('slot'));
    double viewerBottom() =>
        MediaQuery.paddingOf(tester.element(find.byType(MediaViewer))).bottom;
    MediaQueryData frame(double inset) => MediaQueryData(
      size: const Size(390, 800),
      viewInsets: EdgeInsets.only(bottom: inset),
      viewPadding: const EdgeInsets.only(bottom: 48),
      padding: EdgeInsets.only(bottom: math.max(0, 48 - inset)),
    );
    for (final inset in [
      for (var i = 0.0; i <= 358; i += 22) i,
      for (var i = 358.0; i >= 0; i -= 22) i,
    ]) {
      h.media.value = frame(inset);
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.getRect(slot).bottom, 800, reason: 'at an inset of $inset');
    }
    await tester.pump();
    // The slot is 60 high; the viewer's controls stand on it.
    expect(viewerBottom(), 60);
    expectThemedText(tester);
  });

  testWidgets('the slot hears the chrome: shown, its fade, and a dismiss '
      'drag from start to spring back', (tester) async {
    final h = PickerHarness();
    await h.pump(tester, viewerSlot: true);
    await _open(tester, 2);
    final item = h.slotItems.last;
    expect(item.chromeShown.value, isTrue);
    expect(item.chrome.value, 1);
    expect(item.dismissing.value, isFalse);
    final heard = <bool>[];
    item.dismissing.addListener(() => heard.add(item.dismissing.value));

    final gesture = await tester.startGesture(const Offset(195, 400));
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    expect(item.dismissing.value, isTrue);
    expect(item.chromeShown.value, isFalse);
    await tester.pump(const Duration(milliseconds: 250));
    expect(item.chrome.value, 0);

    await gesture.up();
    await tester.pump();
    expect(item.dismissing.value, isFalse);
    expect(item.chromeShown.value, isTrue);
    await tester.pump(const Duration(milliseconds: 300));
    expect(item.chrome.value, 1);
    expect(heard, [true, false]);
    expectThemedText(tester);
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
