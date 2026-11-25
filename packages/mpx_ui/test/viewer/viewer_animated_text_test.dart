import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_ui/mpx_ui.dart';

void main() {
  // The test font is as wide as it is tall: 10 px a character.
  const style = TextStyle(fontSize: 10);

  Widget host(String text, {bool words = false}) => Directionality(
    textDirection: TextDirection.ltr,
    child: Align(
      alignment: Alignment.topLeft,
      child: ViewerAnimatedText(text, style: style, byWords: words),
    ),
  );

  double width(WidgetTester tester) =>
      tester.getSize(find.byType(ViewerAnimatedText)).width;

  testWidgets('a text is as wide as it is', (tester) async {
    await tester.pumpWidget(host('3 of 5'));

    expect(width(tester), 60);
  });

  testWidgets('its width goes from the old text to the new as it changes', (
    tester,
  ) async {
    await tester.pumpWidget(host('9 of 12'));
    expect(width(tester), 70);

    await tester.pumpWidget(host('10 of 12'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final part = width(tester);
    expect(part, inExclusiveRange(70, 80));

    await tester.pump(const Duration(milliseconds: 400));
    expect(width(tester), 80);
  });

  testWidgets('a text that did not change does not animate', (tester) async {
    await tester.pumpWidget(host('3 of 5'));
    await tester.pumpWidget(host('3 of 5'));
    await tester.pump(const Duration(milliseconds: 50));

    expect(width(tester), 60);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('a change takes 320 ms', (tester) async {
    await tester.pumpWidget(host('a'));
    await tester.pumpWidget(host('b'));
    await tester.pump();
    expect(tester.hasRunningAnimations, isTrue);

    await tester.pump(const Duration(milliseconds: 330));
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('it says the text it shows to a screen reader', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(host('2 hours ago', words: true));

    expect(find.bySemanticsLabel('2 hours ago'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('a zero duration changes at once', (tester) async {
    Widget instant(String text) => Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: ViewerAnimatedText(text, style: style, duration: Duration.zero),
      ),
    );
    await tester.pumpWidget(instant('9 of 12'));

    await tester.pumpWidget(instant('10 of 12'));

    expect(width(tester), 80);
    expect(tester.hasRunningAnimations, isFalse);
  });
}
