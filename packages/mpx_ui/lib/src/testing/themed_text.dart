import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// The style a Material app gives text that sits outside any text root
/// (red, monospace, a yellow double underline): what a route, an overlay or
/// a popup shows when it drops its host's text style. A test wraps a surface
/// in it ([unthemedHost]) to stand for a host that gave none.
const TextStyle unthemedTextStyle = TextStyle(
  color: Color(0xD0FF0000),
  fontFamily: 'monospace',
  fontSize: 48,
  fontWeight: FontWeight.w900,
  decoration: TextDecoration.underline,
  decorationColor: Color(0xFFFFFF00),
  decorationStyle: TextDecorationStyle.double,
  debugLabel: 'fallback style; consider putting your text in a Material',
);

/// [child] under [unthemedTextStyle], as a host without a text root.
Widget unthemedHost(Widget child) =>
    DefaultTextStyle(style: unthemedTextStyle, child: child);

/// Fails when any text on screen (below [within] when given) is drawn in a
/// fallback style: underlined, monospace, in the fallback red, or with no
/// size at all (no text root above it).
void expectThemedText(WidgetTester tester, {Finder? within}) {
  final paragraphs = within == null
      ? find.byType(RichText)
      : find.descendant(of: within, matching: find.byType(RichText));
  final failures = <String>[];
  for (final paragraph in tester.widgetList<RichText>(paragraphs)) {
    void visit(InlineSpan span, TextStyle inherited) {
      final style = inherited.merge(span.style);
      if (span is TextSpan && (span.text?.trim().isNotEmpty ?? false)) {
        final decoration = style.decoration;
        final reasons = [
          if (decoration != null && decoration != TextDecoration.none)
            'decorated $decoration',
          if (style.fontFamily == 'monospace') 'monospace',
          if (style.color == unthemedTextStyle.color) 'fallback colour',
          if (style.fontSize == null) 'no size (no text root)',
        ];
        if (reasons.isNotEmpty) {
          failures.add('"${span.text}": ${reasons.join(', ')}');
        }
      }
      if (span is TextSpan) {
        for (final child in span.children ?? const <InlineSpan>[]) {
          visit(child, style);
        }
      }
    }

    visit(paragraph.text, const TextStyle());
  }
  if (failures.isNotEmpty) {
    fail('Text drawn in a fallback style:\n${failures.join('\n')}');
  }
}
