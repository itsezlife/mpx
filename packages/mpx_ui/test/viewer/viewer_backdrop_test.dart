import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_ui/mpx_ui.dart';

import 'viewer_harness.dart';

double _scaleBehind(WidgetTester tester) {
  final transforms = tester.widgetList<Transform>(
    find.ancestor(
      of: find.byKey(ViewerHarness.behindKey),
      matching: find.byType(Transform),
    ),
  );
  if (transforms.isEmpty) return 1;
  return transforms.first.transform.getMaxScaleOnAxis();
}

void main() {
  testWidgets('the surface behind grows to 1.1 as the viewer opens, frame by '
      'frame, from the scope alone', (tester) async {
    final harness = ViewerHarness();
    await harness.pump(tester, open: false, backdropScope: true);
    expect(_scaleBehind(tester), 1);
    final seen = <double>[];
    for (var i = 0; i < 3; i++) {
      // 0.25, 0.5, 0.75 of the 200 ms open.
      await tester.pump(const Duration(milliseconds: 50));
      seen.add(_scaleBehind(tester));
    }
    for (final scale in seen) {
      expect(scale, inExclusiveRange(1, 1.1));
    }
    expect(seen[0], lessThan(seen[1]));
    expect(seen[1], lessThan(seen[2]));
    await tester.pump(const Duration(milliseconds: 51));
    expect(_scaleBehind(tester), closeTo(1.1, 1e-6));
  });

  testWidgets('a dismiss drag rolls it back by how far the picture is '
      'pulled, and the close brings it to 1', (tester) async {
    final harness = ViewerHarness();
    await harness.pump(tester, backdropScope: true);
    final gesture = await tester.startGesture(const Offset(200, 400));
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump();
    final pulled = <double>[];
    for (final dy in [70.0, 100.0, 100.0]) {
      await gesture.moveBy(Offset(0, dy));
      await tester.pump();
      pulled.add(_scaleBehind(tester));
    }
    // Half the height pulled (400 of 800) is back to 1: 1 + 0.1 * (1 - d / 400).
    final drag = harness.state(tester).dragOffset;
    expect(pulled.last, closeTo(1 + 0.1 * (1 - drag / 400), 1e-6));
    expect(pulled[0], greaterThan(pulled[1]));
    expect(pulled[1], greaterThan(pulled[2]));
    await gesture.up();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(harness.closed, 1);
    expect(_scaleBehind(tester), 1);
  });

  testWidgets('the close, frame by frame, settles it back to 1', (
    tester,
  ) async {
    final harness = ViewerHarness();
    await harness.pump(tester, backdropScope: true);
    harness.state(tester).close().ignore();
    await tester.pump();
    final seen = <double>[];
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      seen.add(_scaleBehind(tester));
    }
    expect(seen[0], greaterThan(seen[1]));
    expect(seen[1], greaterThan(seen[2]));
    expect(seen[2], greaterThan(1));
    await tester.pump(const Duration(milliseconds: 60));
    expect(_scaleBehind(tester), 1);
  });

  group('the overlays on the surface', () {
    testWidgets('the item shown is covered as the viewer opens; paging moves '
        'the cover; the close uncovers it at its start', (tester) async {
      final harness = ViewerHarness();
      await harness.pump(tester, open: false);
      expect(harness.bridge.covered, {0});
      await tester.pump(const Duration(milliseconds: 201));
      await tester.dragFrom(const Offset(300, 400), const Offset(-300, 0));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(harness.state(tester).index, 1);
      expect(harness.bridge.covered, {1});
      harness.state(tester).close().ignore();
      await tester.pump();
      expect(harness.bridge.covered, isEmpty, reason: 'at the close start');
      expect(harness.bridge.hidden, isNotEmpty, reason: 'the picture still');
    });

    testWidgets('a ViewerOriginOverlay fades out over 180 ms while covered '
        'and back when uncovered', (tester) async {
      final scope = GlobalKey<ViewerOriginScopeState>();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ViewerOriginScope(
            key: scope,
            child: const ViewerOriginOverlay(
              index: 3,
              child: SizedBox(key: ValueKey('mark'), width: 10, height: 10),
            ),
          ),
        ),
      );
      double opacity() =>
          tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity;
      double shown() => tester
          .renderObject<RenderAnimatedOpacity>(find.byType(AnimatedOpacity))
          .opacity
          .value;
      expect(opacity(), 1);
      scope.currentState!.setCovered(3, covered: true);
      await tester.pump();
      expect(opacity(), 0);
      await tester.pump(const Duration(milliseconds: 90));
      expect(shown(), inExclusiveRange(0, 1));
      await tester.pump(const Duration(milliseconds: 91));
      expect(shown(), 0);
      scope.currentState!.setCovered(3, covered: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 181));
      expect(shown(), 1);
      // Another item's cover leaves it be.
      scope.currentState!.setCovered(4, covered: true);
      await tester.pump();
      expect(opacity(), 1);
    });
  });
}
