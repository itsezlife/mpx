import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_svg/mpx_svg.dart';

const _icon = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24">
  <defs>
    <linearGradient id="g"><stop offset="0" stop-color="#f00"/></linearGradient>
  </defs>
  <g fill="url(#g)"><path d="M0 0h24v24H0z"/></g>
</svg>''';

SvgRejectionReason? _reasonOf(String xml, [SvgLimits? limits]) =>
    SvgSanitizer(limits ?? SvgLimits.standard).check(xml)?.reason;

void main() {
  test('a plain icon passes', () {
    expect(const SvgSanitizer(SvgLimits.standard).check(_icon), isNull);
  });

  test('a script is rejected', () {
    expect(
      _reasonOf(
        '<svg xmlns="http://www.w3.org/2000/svg"><script>x()</script></svg>',
      ),
      SvgRejectionReason.element,
    );
  });

  String svg(String body, {String attributes = ''}) =>
      '<svg xmlns="http://www.w3.org/2000/svg" '
      'xmlns:xlink="http://www.w3.org/1999/xlink" $attributes>$body</svg>';

  test('elements that run code, embed documents or animate are rejected, '
      'with or without a prefix', () {
    for (final element in [
      '<foreignObject><div/></foreignObject>',
      '<iframe/>',
      '<embed/>',
      '<animate attributeName="x"/>',
      '<set attributeName="x" to="1"/>',
      '<svg:script xmlns:svg="http://www.w3.org/2000/svg"/>',
    ]) {
      expect(
        _reasonOf(svg(element)),
        SvgRejectionReason.element,
        reason: element,
      );
    }
  });

  test('an event handler is rejected', () {
    expect(
      _reasonOf(svg('<rect onclick="x()"/>')),
      SvgRejectionReason.eventHandler,
    );
    expect(
      _reasonOf(svg('', attributes: 'onload="x()"')),
      SvgRejectionReason.eventHandler,
    );
  });

  test('a reference out of the document is rejected; one to #id passes', () {
    expect(
      _reasonOf(svg('<image href="https://host/a.png"/>')),
      SvgRejectionReason.externalReference,
    );
    expect(
      _reasonOf(svg('<use xlink:href="file:///etc/passwd#x"/>')),
      SvgRejectionReason.externalReference,
    );
    expect(
      _reasonOf(svg('<rect fill="url(https://host/p.svg#g)"/>')),
      SvgRejectionReason.externalReference,
    );
    expect(
      _reasonOf(svg('<rect style="fill: url(\'//host/x\')"/>')),
      SvgRejectionReason.externalReference,
    );
    expect(
      _reasonOf('<?xml-stylesheet href="https://host/a.css"?>${svg('')}'),
      SvgRejectionReason.externalReference,
    );
    expect(
      _reasonOf(svg('<rect id="a"/><use href="#a" fill="url(#a)"/>')),
      isNull,
    );
  });

  test('an embedded image passes only when the limits allow it', () {
    final image = svg('<image href="data:image/png;base64,iVBORw0KGgo="/>');
    final allowing = SvgLimits.standard.copyWith(allowEmbeddedImages: true);

    expect(_reasonOf(image), SvgRejectionReason.embeddedImage);
    expect(_reasonOf(image, allowing), isNull);
    expect(
      _reasonOf(
        svg('<image href="data:text/html;base64,PHNjcmlwdD4="/>'),
        allowing,
      ),
      SvgRejectionReason.externalReference,
    );
  });

  test('a stylesheet that imports or animates is rejected', () {
    expect(
      _reasonOf(svg('<style>@import "https://host/a.css";</style>')),
      SvgRejectionReason.stylesheet,
    );
    expect(
      _reasonOf(svg('<style><![CDATA[@keyframes k {}]]></style>')),
      SvgRejectionReason.stylesheet,
    );
    expect(
      _reasonOf(svg('<rect style="animation: k 1s"/>')),
      SvgRejectionReason.stylesheet,
    );
    expect(_reasonOf(svg('<style>.a { fill: red }</style>')), isNull);
  });

  test('a document type that declares entities is rejected; a public one, '
      'which nothing fetches, passes', () {
    const bomb = '''
<?xml version="1.0"?>
<!DOCTYPE svg [
  <!ENTITY a "aaaaaaaaaa">
  <!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">
]>
<svg xmlns="http://www.w3.org/2000/svg"><text>&b;</text></svg>''';

    expect(_reasonOf(bomb), SvgRejectionReason.doctype);
    expect(
      _reasonOf(
        '<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" '
        '"http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">${svg('')}',
      ),
      isNull,
    );
  });

  test('more elements than the cap are rejected', () {
    final limits = SvgLimits.standard.copyWith(maxElements: 10);

    // The root and nine rects: ten.
    expect(_reasonOf(svg('<rect/>' * 9), limits), isNull);
    expect(
      _reasonOf(svg('<rect/>' * 10), limits),
      SvgRejectionReason.tooManyElements,
    );
  });

  test('nesting deeper than the cap is rejected', () {
    final limits = SvgLimits.standard.copyWith(maxDepth: 5);

    // The root and four groups: five deep.
    expect(_reasonOf(svg('${'<g>' * 4}${'</g>' * 4}'), limits), isNull);
    expect(
      _reasonOf(svg('${'<g>' * 5}${'</g>' * 5}'), limits),
      SvgRejectionReason.tooDeep,
    );
  });

  test('a <use> chain that doubles at each link is rejected without '
      'expanding it', () {
    // 40 links of two uses each: 2^40 elements once expanded, 120 written.
    final links = StringBuffer('<defs><rect id="l0"/>');
    for (var i = 1; i <= 40; i++) {
      links.write(
        '<g id="l$i"><use href="#l${i - 1}"/><use href="#l${i - 1}"/></g>',
      );
    }
    links.write('</defs><use href="#l40"/>');

    expect(_reasonOf(svg('$links')), SvgRejectionReason.useExpansion);
  });

  test('a <use> under the expansion cap passes; one of nothing counts '
      'nothing', () {
    final limits = SvgLimits.standard.copyWith(maxUseExpansion: 12);
    // Written: root, defs, g and three rects (6). Each use adds itself and
    // the group's four: one use is 11, three are 21.
    const group = '<defs><g id="g"><rect/><rect/><rect/></g></defs>';

    expect(_reasonOf(svg('$group<use href="#g"/>'), limits), isNull);
    expect(
      _reasonOf(svg('$group${'<use href="#g"/>' * 3}'), limits),
      SvgRejectionReason.useExpansion,
    );
    expect(_reasonOf(svg('<use href="#nothing"/>'), limits), isNull);
  });

  test('a <use> that references itself through another is rejected', () {
    expect(
      _reasonOf(
        svg('<g id="a"><use href="#b"/></g><g id="b"><use href="#a"/></g>'),
      ),
      SvgRejectionReason.useExpansion,
    );
  });

  test('text that is not an SVG document is rejected', () {
    for (final text in [
      '',
      'not xml',
      '<svg><g></svg>',
      '<html><body/></html>',
      '<svg/><svg/>',
    ]) {
      expect(_reasonOf(text), SvgRejectionReason.notSvg, reason: text);
    }
  });

  test('limits compare by value', () {
    expect(
      SvgLimits.standard.copyWith(maxDepth: 7),
      SvgLimits.standard.copyWith(maxDepth: 7),
    );
    expect(SvgLimits.standard.copyWith(maxDepth: 7), isNot(SvgLimits.standard));
  });
}
