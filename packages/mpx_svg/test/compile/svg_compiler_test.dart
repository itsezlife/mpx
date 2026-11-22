import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_svg/mpx_svg.dart';

Uint8List _utf8(String text) => Uint8List.fromList(utf8.encode(text));

final Uint8List _square = _utf8(
  '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"> '
  '<rect width="10" height="10" fill="#00f"/></svg>',
);

Future<SvgRejectionReason?> _rejectionOf(SvgCompilation compilation) async {
  try {
    await compilation.result;
    return null;
  } on SvgRejection catch (rejection) {
    return rejection.reason;
  }
}

void main() {
  const compiler = SvgCompiler();

  test('compiles a document to the vector binary form', () async {
    final compiled = await compiler.compile(SvgSource.bytes(_square)).result;

    // The form starts with the codec's magic number, 0x00882d62 little end.
    expect(compiled, isNotNull);
    expect(compiled!.sublist(0, 4), [0x62, 0x2d, 0x88, 0x00]);
  });

  test('a document the sanitizer refuses fails with its rejection', () async {
    final compilation = compiler.compile(
      SvgSource.bytes(
        _utf8('<svg xmlns="http://www.w3.org/2000/svg"><script/></svg>'),
      ),
    );

    expect(await _rejectionOf(compilation), SvgRejectionReason.element);
  });

  test('bytes that are not UTF-8 are not SVG', () async {
    final compilation = compiler.compile(
      SvgSource.bytes(Uint8List.fromList([0x3c, 0xff, 0xfe, 0x3e])),
    );

    expect(await _rejectionOf(compilation), SvgRejectionReason.notSvg);
  });

  test('a byte-order mark before the root is read past', () async {
    final compiled = await compiler
        .compile(
          SvgSource.bytes(Uint8List.fromList([0xef, 0xbb, 0xbf, ..._square])),
        )
        .result;

    expect(compiled, isNotNull);
  });

  test('input over the cap is refused, in memory and in a file', () async {
    const small = SvgCompiler(
      SvgLimits(
        maxInputBytes: 64,
        maxPixelEdge: 4096,
        maxElements: 100,
        maxDepth: 10,
        maxUseExpansion: 100,
        maxCompileTime: Duration(seconds: 5),
      ),
    );
    final directory = Directory.systemTemp.createTempSync('mpx_svg_test');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/big.svg')..writeAsBytesSync(_square);

    expect(
      await _rejectionOf(small.compile(SvgSource.bytes(_square))),
      SvgRejectionReason.tooLarge,
    );
    expect(
      await _rejectionOf(small.compile(SvgSource.file(file.path))),
      SvgRejectionReason.tooLarge,
    );
  });

  test('a file is read where it is compiled', () async {
    final directory = Directory.systemTemp.createTempSync('mpx_svg_test');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/a.svg')..writeAsBytesSync(_square);

    final compiled = await compiler.compile(SvgSource.file(file.path)).result;

    expect(compiled, await compiler.compile(SvgSource.bytes(_square)).result);
  });

  test('a compile past the time cap is stopped as too slow', () async {
    final hasty = SvgCompiler(
      SvgLimits.standard.copyWith(maxCompileTime: Duration.zero),
    );

    expect(
      await _rejectionOf(hasty.compile(SvgSource.bytes(_square))),
      SvgRejectionReason.tooSlow,
    );
  });

  test('a cancelled compile answers null', () async {
    final compilation = compiler.compile(SvgSource.bytes(_square))..cancel();

    expect(await compilation.result, isNull);
  });
}
