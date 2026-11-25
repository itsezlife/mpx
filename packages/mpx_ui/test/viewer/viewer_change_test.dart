import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_ui/mpx_ui.dart';

void main() {
  Widget host(Object id, {ViewerChangeTransition? transition, int dir = 1}) =>
      Directionality(
        textDirection: TextDirection.ltr,
        child: ViewerChangeSwitcher(
          direction: dir,
          transition: transition ?? ViewerChangeTransition.slide,
          child: Text('item $id', key: ValueKey(id)),
        ),
      );

  double opacityOf(WidgetTester tester, String text) => tester
      .widgetList<Opacity>(
        find.ancestor(of: find.text(text), matching: find.byType(Opacity)),
      )
      .fold(1, (value, widget) => value * widget.opacity);

  testWidgets('a changed child crossfades with the one it replaces, which '
      'leaves when it is done', (tester) async {
    await tester.pumpWidget(host(1));
    expect(find.text('item 1'), findsOneWidget);

    await tester.pumpWidget(host(2));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('item 1'), findsOneWidget);
    expect(find.text('item 2'), findsOneWidget);
    expect(opacityOf(tester, 'item 1'), inExclusiveRange(0, 1));
    expect(opacityOf(tester, 'item 2'), inExclusiveRange(0, 1));

    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('item 1'), findsNothing);
    expect(opacityOf(tester, 'item 2'), 1);
  });

  testWidgets('the slide goes the way the item index goes', (tester) async {
    await tester.pumpWidget(host(1));
    await tester.pumpWidget(host(2));
    await tester.pump(const Duration(milliseconds: 60));

    // To a later item: the new text comes from the right, the old goes left.
    final forwardNew = tester.getTopLeft(find.text('item 2')).dx;
    final forwardOld = tester.getTopLeft(find.text('item 1')).dx;
    expect(forwardNew, greaterThan(forwardOld));

    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpWidget(host(3, dir: -1));
    await tester.pump(const Duration(milliseconds: 60));

    expect(
      tester.getTopLeft(find.text('item 3')).dx,
      lessThan(tester.getTopLeft(find.text('item 2')).dx),
    );
  });

  testWidgets('a fade does not slide', (tester) async {
    await tester.pumpWidget(host(1, transition: ViewerChangeTransition.fade));
    await tester.pumpWidget(host(2, transition: ViewerChangeTransition.fade));
    await tester.pump(const Duration(milliseconds: 60));

    expect(
      tester.getTopLeft(find.text('item 2')).dx,
      tester.getTopLeft(find.text('item 1')).dx,
    );
  });

  testWidgets('none changes at once', (tester) async {
    await tester.pumpWidget(host(1, transition: ViewerChangeTransition.none));
    await tester.pumpWidget(host(2, transition: ViewerChangeTransition.none));
    await tester.pump();

    expect(find.text('item 1'), findsNothing);
    expect(find.text('item 2'), findsOneWidget);
  });

  testWidgets('the same child is not animated again', (tester) async {
    await tester.pumpWidget(host(1));
    await tester.pumpWidget(host(1));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('item 1'), findsOneWidget);
    expect(opacityOf(tester, 'item 1'), 1);
  });
}
