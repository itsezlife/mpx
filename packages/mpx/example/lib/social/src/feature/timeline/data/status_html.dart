import 'package:mpx_example/social/src/feature/timeline/model/post.dart';

/// Reads the markup a Mastodon server sends as a status's `content` into the
/// Markdown the post's text is drawn from.
///
/// The server sanitizes it to a small vocabulary: paragraphs, line breaks,
/// links (hashtags and mentions among them), and spans, of which the
/// `invisible` ones hide the scheme of a long link and `ellipsis` marks where
/// the link was cut. Everything else is dropped to its text. A hashtag
/// becomes `[#tag](hashtag:tag)` and a mention `[@name](mention:<url>)`, the
/// spans the renderer styles and reports taps on apart from links.
abstract final class StatusHtml {
  static final RegExp _token = RegExp('<[^>]*>|[^<]+');
  static final RegExp _attribute = RegExp(
    r'''([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')''',
  );
  static final RegExp _entity = RegExp(r'&(#x[0-9a-fA-F]+|#\d+|[a-zA-Z]+);');
  static final RegExp _tagName = RegExp(r'^</?\s*([a-zA-Z0-9]+)');

  // Every character Markdown reads as syntax and a backslash takes back.
  static final RegExp _syntax = RegExp(r'[!#$()*+\-.=>\[\\\]_`{|}~]');

  static const Map<String, String> _named = {
    'amp': '&',
    'lt': '<',
    'gt': '>',
    'quot': '"',
    'apos': "'",
    'nbsp': ' ',
  };

  /// The text of [html].
  static PostText parse(String html) {
    final markdown = StringBuffer();
    final plain = StringBuffer();
    // The open spans: whether each hides its text, and whether it marks where
    // a link was cut.
    final spans = <({bool hides, bool cut})>[];
    // The anchor being read: its attributes and what it shows so far.
    Map<String, String>? anchor;
    final shown = StringBuffer();
    var hidden = 0;

    void addText(String text) {
      if (hidden > 0 || text.isEmpty) return;
      if (anchor != null) {
        shown.write(text);
        return;
      }
      markdown.write(_escape(text));
      plain.write(text);
    }

    void addBreak(String text) {
      if (hidden > 0) return;
      markdown.write(text);
      plain.write(text);
    }

    for (final match in _token.allMatches(html)) {
      final token = match.group(0)!;
      if (!token.startsWith('<')) {
        addText(_decode(token));
        continue;
      }
      final closing = token.startsWith('</');
      final name = _tagName.firstMatch(token)?.group(1)?.toLowerCase();
      switch ((name, closing)) {
        case ('br', _):
          addBreak('\n');
        case ('p', true):
          addBreak('\n\n');
        case ('a', false):
          anchor = _attributes(token);
          shown.clear();
        case ('a', true):
          final open = anchor;
          anchor = null;
          if (open != null) {
            final text = shown.toString();
            markdown.write(_anchor(open, text));
            plain.write(text);
          }
        case ('span', false):
          final classes = (_attributes(token)['class'] ?? '').split(' ');
          final span = (
            hides: classes.contains('invisible'),
            cut: classes.contains('ellipsis'),
          );
          spans.add(span);
          if (span.hides) hidden++;
        case ('span', true):
          if (spans.isEmpty) break;
          final span = spans.removeLast();
          if (span.hides) hidden--;
          // The link was cut where its visible part ends.
          if (span.cut && anchor != null) shown.write('…');
        case ('li', false):
          addText('• ');
        case ('li', true):
          addBreak('\n');
      }
    }
    final text = PostText(
      markdown: _trimmed(markdown.toString()),
      plain: _trimmed(plain.toString()),
    );
    return text.isEmpty ? PostText.empty : text;
  }

  // The span a link is: a tag, a mention or a web link, by its classes.
  static String _anchor(Map<String, String> anchor, String text) {
    final classes = (anchor['class'] ?? '').split(' ');
    final href = anchor['href'] ?? '';
    if (classes.contains('hashtag')) {
      final tag = text.startsWith('#') ? text.substring(1) : text;
      return '[#${_escape(tag)}](hashtag:${Uri.encodeComponent(tag)})';
    }
    final label = _escape(text.isEmpty ? href : text);
    if (classes.contains('mention')) {
      return '[$label](mention:${Uri.encodeComponent(href)})';
    }
    return '[$label](${_destination(href)})';
  }

  // A destination the renderer reads whole: no space, no parenthesis.
  static String _destination(String url) =>
      url.replaceAll(' ', '%20').replaceAll('(', '%28').replaceAll(')', '%29');

  static String _escape(String text) =>
      text.replaceAllMapped(_syntax, (match) => '\\${match.group(0)}');

  static Map<String, String> _attributes(String tag) => {
    for (final m in _attribute.allMatches(tag))
      m.group(1)!: _decode(m.group(2) ?? m.group(3) ?? ''),
  };

  static String _decode(String text) => text.replaceAllMapped(_entity, (m) {
    final body = m.group(1)!;
    if (body.startsWith('#x')) {
      final code = int.tryParse(body.substring(2), radix: 16);
      return code == null ? m.group(0)! : String.fromCharCode(code);
    }
    if (body.startsWith('#')) {
      final code = int.tryParse(body.substring(1));
      return code == null ? m.group(0)! : String.fromCharCode(code);
    }
    return _named[body] ?? m.group(0)!;
  });

  // No breaks at either end, and no run of three or more.
  static String _trimmed(String text) => text
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .replaceAll(RegExp(r'^\n+|\n+$'), '');
}
