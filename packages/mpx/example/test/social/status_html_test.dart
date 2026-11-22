import 'package:flutter_md/flutter_md.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_example/social/src/feature/timeline/data/status_html.dart';

void main() {
  test('paragraphs and line breaks', () {
    final text = StatusHtml.parse('<p>One<br>two</p><p>Three</p>');
    expect(text.markdown, 'One\ntwo\n\nThree');
    expect(text.plain, 'One\ntwo\n\nThree');
  });

  test('hashtags and mentions are spans of their own, links stay links', () {
    final text = StatusHtml.parse(
      [
        '<p><a href="https://m.example/tags/cats" class="mention hashtag">',
        '#<span>cats</span></a> ',
        '<span class="h-card"><a href="https://m.example/@a" ',
        'class="u-url mention">@<span>a</span></a></span> ',
        '<a href="https://example.com/a/b">',
        '<span class="invisible">https://</span>',
        '<span class="ellipsis">example.com/a</span>',
        '<span class="invisible">/b</span></a></p>',
      ].join(),
    );
    expect(
      text.markdown,
      [
        '[#cats](hashtag:cats)',
        '[@a](mention:https%3A%2F%2Fm.example%2F%40a)',
        r'[example\.com/a…](https://example.com/a/b)',
      ].join(' '),
    );
    expect(text.plain, '#cats @a example.com/a…');
  });

  test('entities are decoded', () {
    final text = StatusHtml.parse('<p>Tom &amp; Jerry &lt;3 &#33; &#x21;</p>');
    expect(text.plain, 'Tom & Jerry <3 ! !');
  });

  test('what Markdown reads as syntax is taken back with a backslash', () {
    final text = StatusHtml.parse(
      '<p>5 * 6 = 30 and snake_case, [x](y) #1</p>',
    );
    expect(text.markdown, contains(r'5 \* 6 \= 30'));
    // The renderer's parser reads it back as the words, not as markup.
    final parsed = Markdown.fromString(text.markdown);
    expect(parsed.markdown, text.markdown);
    expect(parsed.blocks, hasLength(1));
    expect(
      parsed.text.replaceAll(RegExp(r'\s+'), ' ').trim(),
      '5 * 6 = 30 and snake_case, [x](y) #1',
    );
  });

  test('breaks at either end and runs of them are trimmed', () {
    final text = StatusHtml.parse('<p></p><p>A</p><p></p><p>B</p><br>');
    expect(text.plain, 'A\n\nB');
  });

  test('a post with no words has no text', () {
    expect(StatusHtml.parse('<p></p>').isEmpty, isTrue);
  });
}
