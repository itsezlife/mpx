import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_ui/mpx_ui.dart';

void main() {
  group('the band rule', () {
    test('nothing between the bands', () {
      expect(EdgeAutoScroll.depthOf(400, top: 100, bottom: 800, edge: 60), 0);
    });

    test('deeper is faster, up to the most at the end and past it', () {
      expect(EdgeAutoScroll.depthOf(770, top: 100, bottom: 800, edge: 60), 0.5);
      expect(EdgeAutoScroll.depthOf(800, top: 100, bottom: 800, edge: 60), 1);
      expect(EdgeAutoScroll.depthOf(900, top: 100, bottom: 800, edge: 60), 1);
      expect(
        EdgeAutoScroll.depthOf(130, top: 100, bottom: 800, edge: 60),
        -0.5,
      );
    });
  });

  testWidgets('a finger held still keeps scrolling while the list moves up '
      'under it (a sheet rising), until it lets go', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ListView.builder(
          controller: controller,
          itemExtent: 100,
          itemCount: 200,
          itemBuilder: (context, i) => const SizedBox(),
        ),
      ),
    );
    // The list's part on screen: its top rises 10 a frame (the sheet), its
    // bottom is the screen's.
    var top = 400.0;
    final steps = <Offset>[];
    final scroll = EdgeAutoScroll(
      vsync: tester,
      position: () => controller.position,
      viewport: () => Rect.fromLTRB(0, top, 400, 600),
      onStep: steps.add,
    );
    addTearDown(scroll.dispose);
    // 30 into the bottom band of 60: half speed, 8 a frame.
    scroll.hold(const Offset(200, 570));
    expect(scroll.active, isTrue);
    for (var i = 0; i < 30; i++) {
      top = (top - 10).clamp(0.0, 600.0);
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(controller.offset, closeTo(29 * 8, 16));
    expect(steps, hasLength(greaterThan(25)));
    expect(steps.every((s) => s == const Offset(200, 570)), isTrue);

    scroll.release();
    final rest = controller.offset;
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.offset, rest);
    expect(scroll.active, isFalse);
  });

  testWidgets('a finger that leaves the band stops it', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ListView.builder(
          controller: controller,
          itemExtent: 100,
          itemCount: 200,
          itemBuilder: (context, i) => const SizedBox(),
        ),
      ),
    );
    final scroll = EdgeAutoScroll(
      vsync: tester,
      position: () => controller.position,
      viewport: () => const Rect.fromLTRB(0, 0, 400, 600),
    )..hold(const Offset(200, 590));
    addTearDown(scroll.dispose);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    scroll.hold(const Offset(200, 300));
    expect(scroll.active, isFalse);
    final rest = controller.offset;
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.offset, rest);
  });
}
