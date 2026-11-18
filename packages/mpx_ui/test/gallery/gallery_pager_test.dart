import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_ui/mpx_ui.dart';

const _size = Size(400, 800);

/// A pager of [count] pages 400 x 800, recording what it tells.
final class _Pager {
  final List<int> changed = [];
  final List<String> dismiss = [];
  final List<Offset> taps = [];
  final List<String> lives = [];
  late GalleryPagerController controller;

  double position() => controller.position.value;

  Future<void> pump(
    WidgetTester tester, {
    int count = 3,
    int initialPage = 0,
    GalleryPagerPhysics physics = GalleryPagerPhysics.$Android,
    GalleryPageTransition transition = const GalleryPageTransition.strip(),
    double gap = 15,
    GalleryKeepAlive keepAlive = const GalleryKeepAlive.around(1),
    GalleryClaim? dismiss,
    TextDirection? textDirection,
    Axis axis = Axis.horizontal,
  }) async {
    tester.view.physicalSize = _size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    controller = GalleryPagerController(initialPage: initialPage);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: GalleryPager(
          controller: controller,
          count: count,
          physics: physics,
          transition: transition,
          gap: gap,
          keepAlive: keepAlive,
          dismiss: dismiss,
          axis: axis,
          textDirection: textDirection,
          onPageChanged: changed.add,
          onDismissStart: () => this.dismiss.add('start'),
          onDismissUpdate: (offset) => this.dismiss.add('$offset'),
          onDismissEnd: (offset, velocity) => this.dismiss.add('end $offset'),
          onTap: taps.add,
          pageBuilder: (context, index) => _Page(index, lives),
        ),
      ),
    );
  }
}

class _Page extends StatefulWidget {
  const _Page(this.index, this.lives);

  final int index;
  final List<String> lives;

  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  @override
  void initState() {
    super.initState();
    widget.lives.add('+${widget.index}');
  }

  @override
  void dispose() {
    widget.lives.add('-${widget.index}');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xFF223344),
    child: Center(child: Text('page ${widget.index}')),
  );
}

// Android: 400 wide with a 15 px gap, a page is 415 px of drag.
const double _stride = 415;

void main() {
  group('the decision, from the down point', () {
    testWidgets(
      'Android pages once the drag is 12 px longer across than down; the '
      'distance that decided it is swallowed',
      (tester) async {
        final pager = _Pager();
        await pager.pump(tester);

        final gesture = await tester.startGesture(const Offset(300, 400));
        await gesture.moveBy(const Offset(-18, 7));
        await tester.pump();
        expect(pager.position(), 0);

        await gesture.moveBy(const Offset(-2, 0));
        await tester.pump();
        // Claimed at 20 px, 12 more than the 7 down; nothing moved yet.
        expect(pager.position(), 0);

        await gesture.moveBy(const Offset(-83, 30));
        await tester.pump();
        expect(pager.position(), closeTo(83 / _stride, 1e-9));
        await gesture.up();
        await tester.pump(const Duration(seconds: 1));
      },
    );

    testWidgets('the dismiss is tested first and locks the gesture', (
      tester,
    ) async {
      final pager = _Pager();
      await pager.pump(
        tester,
        dismiss: const GalleryClaim.dominant(slop: 30, ratio: 2),
      );

      final gesture = await tester.startGesture(const Offset(200, 400));
      await gesture.moveBy(const Offset(-10, 30));
      await tester.pump();
      expect(pager.dismiss, ['start']);

      // Sideways now: still the dismiss, the pager never moves.
      await gesture.moveBy(const Offset(-200, 20));
      await tester.pump();
      expect(pager.position(), 0);
      expect(pager.dismiss.last, '20.0');
      await gesture.up();
      await tester.pump();
      expect(pager.dismiss.last, 'end 20.0');
    });

    testWidgets('once paging, a vertical move never dismisses', (tester) async {
      final pager = _Pager();
      await pager.pump(
        tester,
        dismiss: const GalleryClaim.dominant(slop: 30, ratio: 2),
      );

      final gesture = await tester.startGesture(const Offset(300, 400));
      await gesture.moveBy(const Offset(-25, 5));
      await tester.pump();
      await gesture.moveBy(const Offset(-10, 200));
      await tester.pump();
      expect(pager.dismiss, isEmpty);
      expect(pager.position(), closeTo(10 / _stride, 1e-9));
      await gesture.up();
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a diagonal under both rules does neither, and is no tap', (
      tester,
    ) async {
      final pager = _Pager();
      await pager.pump(
        tester,
        dismiss: const GalleryClaim.dominant(slop: 30, ratio: 2),
      );

      final gesture = await tester.startGesture(const Offset(300, 400));
      await gesture.moveBy(const Offset(-20, 15));
      await tester.pump();
      await gesture.moveBy(const Offset(-10, 10));
      await tester.pump();
      await gesture.up();
      await tester.pump(const Duration(seconds: 1));

      expect(pager.position(), 0);
      expect(pager.dismiss, isEmpty);
      expect(pager.taps, isEmpty);
    });

    testWidgets('iOS pages past its 10 pt slop when more across than down', (
      tester,
    ) async {
      final pager = _Pager();
      await pager.pump(tester, physics: GalleryPagerPhysics.$IOS, gap: 40);

      final gesture = await tester.startGesture(const Offset(300, 400));
      await gesture.moveBy(const Offset(-9, 2));
      await tester.pump();
      await gesture.moveBy(const Offset(-1, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-44, 0));
      await tester.pump();
      expect(pager.position(), closeTo(44 / 440, 1e-9));
      await gesture.up();
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a tap goes to the page', (tester) async {
      final pager = _Pager();
      await pager.pump(tester);

      await tester.tapAt(const Offset(200, 400));
      await tester.pump();
      expect(pager.taps, [const Offset(200, 400)]);
    });
  });

  group('release and settle', () {
    Future<void> dragBy(WidgetTester tester, double dx) async {
      final gesture = await tester.startGesture(const Offset(350, 400));
      // Claimed past the margin, then followed; slow, so no velocity.
      await gesture.moveBy(const Offset(-20, 0));
      await tester.pump();
      await gesture.moveBy(Offset(dx, 0));
      await tester.pump();
      await gesture.up();
      await tester.pump();
    }

    testWidgets('Android: under a third of a page goes back', (tester) async {
      final pager = _Pager();
      await pager.pump(tester);

      await dragBy(tester, -138);
      await tester.pump(const Duration(milliseconds: 251));
      expect(pager.position(), 0);
      expect(pager.changed, isEmpty);
    });

    testWidgets(
      'Android: a third goes on, settling 250 ms, and tells the page as it '
      'lands',
      (tester) async {
        final pager = _Pager();
        await pager.pump(tester);

        await dragBy(tester, -139);
        await tester.pump(const Duration(milliseconds: 125));
        expect(pager.position(), allOf(greaterThan(0.34), lessThan(1)));
        expect(pager.changed, isEmpty);
        expect(pager.controller.page, 0);

        await tester.pump(const Duration(milliseconds: 126));
        expect(pager.position(), 1);
        expect(pager.changed, [1]);
        expect(pager.controller.page, 1);
      },
    );

    testWidgets('Android: a flick of 650 px/s goes on however short', (
      tester,
    ) async {
      final pager = _Pager();
      await pager.pump(tester);

      await tester.flingFrom(const Offset(300, 400), const Offset(-60, 0), 700);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(pager.changed, [1]);
    });

    testWidgets('Android: a slower flick goes back', (tester) async {
      final pager = _Pager();
      await pager.pump(tester);

      await tester.flingFrom(const Offset(300, 400), const Offset(-60, 0), 500);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(pager.changed, isEmpty);
      expect(pager.position(), 0);
    });

    testWidgets('past the first page the page follows a third of the drag', (
      tester,
    ) async {
      final pager = _Pager();
      await pager.pump(tester);

      final gesture = await tester.startGesture(const Offset(50, 400));
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(90, 0));
      await tester.pump();
      expect(pager.position(), closeTo(-30 / _stride, 1e-9));
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 251));
      expect(pager.position(), 0);
    });

    testWidgets('one drag moves one page at most', (tester) async {
      final pager = _Pager();
      await pager.pump(tester);

      final gesture = await tester.startGesture(const Offset(390, 400));
      await gesture.moveBy(const Offset(-20, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-380, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-380, 0));
      await tester.pump();
      expect(pager.position(), 1);
      await gesture.up();
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('Android ignores a touch while the page settles', (
      tester,
    ) async {
      final pager = _Pager();
      await pager.pump(tester);

      await dragBy(tester, -200);
      await tester.pump(const Duration(milliseconds: 100));
      final gesture = await tester.startGesture(const Offset(300, 400));
      await gesture.moveBy(const Offset(100, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(100, 0));
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 300));
      expect(pager.changed, [1]);
      expect(pager.position(), 1);
    });

    testWidgets('iOS catches the settle under the finger', (tester) async {
      final pager = _Pager();
      await pager.pump(tester, physics: GalleryPagerPhysics.$IOS, gap: 40);

      final first = await tester.startGesture(const Offset(350, 400));
      await first.moveBy(const Offset(-20, 0));
      await tester.pump();
      await first.moveBy(const Offset(-240, 0));
      await tester.pump();
      await first.up();
      await tester.pump(const Duration(milliseconds: 50));
      final caught = pager.position();
      expect(caught, allOf(greaterThan(0.5), lessThan(1)));

      final gesture = await tester.startGesture(const Offset(300, 400));
      await tester.pump(const Duration(milliseconds: 100));
      // Held still: the page stays where it was caught.
      expect(pager.position(), closeTo(caught, 1e-9));
      await gesture.moveBy(const Offset(44, 0));
      await tester.pump();
      expect(pager.position(), closeTo(caught - 0.1, 1e-9));
      await gesture.up();
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('animateTo settles; a page further away is jumped to', (
      tester,
    ) async {
      final pager = _Pager();
      await pager.pump(tester, count: 5);

      final done = pager.controller.animateTo(1);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(pager.position(), allOf(greaterThan(0), lessThan(1)));
      await tester.pump(const Duration(milliseconds: 200));
      await done;
      expect(pager.changed, [1]);

      await pager.controller.animateTo(4);
      expect(pager.position(), 4);
      expect(pager.changed, [1, 4]);
    });
  });

  group('drawing', () {
    testWidgets('a strip places the next page a page and a gap away', (
      tester,
    ) async {
      final pager = _Pager();
      await pager.pump(tester);

      final gesture = await tester.startGesture(const Offset(350, 400));
      await gesture.moveBy(const Offset(-20, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-100, 0));
      await tester.pump();
      expect(
        tester.getTopLeft(find.text('page 0')).dx,
        closeTo(tester.getTopLeft(find.text('page 1')).dx - _stride, 0.01),
      );
      await gesture.up();
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('right to left: a drag to the right goes to the next page', (
      tester,
    ) async {
      final pager = _Pager();
      await pager.pump(tester, textDirection: TextDirection.rtl);

      final gesture = await tester.startGesture(const Offset(50, 400));
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(200, 0));
      await tester.pump();
      expect(pager.position(), closeTo(200 / _stride, 1e-9));
      // The next page comes in from the left.
      expect(tester.getCenter(find.text('page 1')).dx, lessThan(200));
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(pager.changed, [1]);
    });

    testWidgets('a vertical pager pages on a drag up', (tester) async {
      final pager = _Pager();
      await pager.pump(
        tester,
        axis: Axis.vertical,
        physics: GalleryPagerPhysics.feed,
        gap: 0,
      );

      await tester.flingFrom(
        const Offset(200, 600),
        const Offset(0, -300),
        1000,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(pager.changed, [1]);
    });
  });

  group('keep-alive', () {
    testWidgets('around(1) keeps the page left until it is two away', (
      tester,
    ) async {
      final pager = _Pager();
      await pager.pump(tester, count: 4);
      expect(pager.lives, ['+0']);

      pager.controller.jumpTo(1);
      await tester.pump();
      expect(pager.lives, ['+0', '+1']);

      pager.controller.jumpTo(2);
      await tester.pump();
      expect(pager.lives, ['+0', '+1', '+2', '-0']);
    });

    testWidgets('none builds only what shows', (tester) async {
      final pager = _Pager();
      await pager.pump(tester, keepAlive: const GalleryKeepAlive.none());

      pager.controller.jumpTo(1);
      await tester.pump();
      expect(pager.lives, ['+0', '+1', '-0']);
    });

    testWidgets('a kept page is offstage: not painted, not hit', (
      tester,
    ) async {
      final pager = _Pager();
      await pager.pump(tester);
      pager.controller.jumpTo(1);
      await tester.pump();

      expect(find.text('page 0'), findsNothing);
      expect(find.text('page 0', skipOffstage: false), findsOneWidget);
    });
  });

  group('side taps and semantics', () {
    testWidgets('Android: a tap on a side strip pages at once', (tester) async {
      final pager = _Pager();
      await pager.pump(tester, initialPage: 1);

      await tester.tapAt(const Offset(20, 400));
      await tester.pump();
      expect(pager.changed, [0]);
      expect(pager.position(), 0);

      // No page before the first: the tap is the page's.
      await tester.tapAt(const Offset(20, 400));
      await tester.pump();
      expect(pager.changed, [0]);
      expect(pager.taps, [const Offset(20, 400)]);

      // Over the bars it is the page's too.
      await tester.tapAt(const Offset(380, 50));
      await tester.pump();
      expect(pager.changed, [0]);
    });

    testWidgets('the semantics scroll actions page', (tester) async {
      final handle = tester.ensureSemantics();
      final pager = _Pager();
      await pager.pump(tester);

      final node = tester.getSemantics(
        find.byKey(const ValueKey('mpx-gallery-pager')),
      );
      expect(
        node.getSemanticsData().hasAction(SemanticsAction.scrollLeft),
        isTrue,
      );
      expect(
        node.getSemanticsData().hasAction(SemanticsAction.scrollRight),
        isFalse,
      );
      tester.semantics.scrollLeft();
      await tester.pumpAndSettle();
      expect(pager.changed, [1]);
      handle.dispose();
    });
  });
}
