import 'dart:convert';
import 'dart:typed_data';

import 'package:mpx_svg/src/policy/svg_limits.dart';
import 'package:mpx_svg/src/policy/svg_sanitizer.dart';
import 'package:vector_graphics_compiler/vector_graphics_compiler.dart';

/// The work of one compile, wherever it runs: SVG bytes to the compiled
/// vector form, or an [SvgRejection].
///
/// Pure and synchronous, so the worker isolate runs it as is and the web
/// runs it in place. Gzipped input is inflated by [inflate], which the
/// platform gives (null where it cannot: the document is then unreadable).
abstract final class SvgCompileJob {
  /// Compiles [bytes] under [limits]; throws an [SvgRejection].
  static Uint8List run(
    Uint8List bytes,
    SvgLimits limits, {
    required SvgInflate? inflate,
  }) {
    if (bytes.length > limits.maxInputBytes) {
      throw SvgRejection(
        SvgRejectionReason.tooLarge,
        '${bytes.length} > ${limits.maxInputBytes} bytes',
      );
    }
    final document = isGzip(bytes)
        ? switch (inflate) {
            final inflate? => inflate(bytes, limits.maxInflatedBytes),
            null => throw const SvgRejection(
              SvgRejectionReason.unreadable,
              'gzip cannot be inflated here',
            ),
          }
        : bytes;
    final String text;
    try {
      text = const Utf8Decoder().convert(document);
    } on FormatException catch (error) {
      throw SvgRejection(
        SvgRejectionReason.notSvg,
        'not UTF-8: ${error.message}',
      );
    }
    // A byte-order mark is not markup; the parser would call it text before
    // the root.
    final xml = text.startsWith('﻿') ? text.substring(1) : text;
    if (SvgSanitizer(limits).check(xml) case final rejection?) {
      throw rejection;
    }
    try {
      // The optimizers need a native path library at run time that an app
      // does not ship; without them the form is a little larger, drawn the
      // same.
      return encodeSvg(
        xml: xml,
        debugName: 'svg',
        enableMaskingOptimizer: false,
        enableClippingOptimizer: false,
        enableOverdrawOptimizer: false,
      );
    } on Object catch (error) {
      throw SvgRejection(SvgRejectionReason.unreadable, '$error');
    }
  }

  /// Whether [bytes] start with the gzip magic number.
  static bool isGzip(Uint8List bytes) =>
      bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b;
}

/// Inflates gzipped [bytes] to at most [cap] bytes; throws an [SvgRejection]
/// past the cap ([SvgRejectionReason.tooLarge]) or for damaged data
/// ([SvgRejectionReason.unreadable]).
typedef SvgInflate = Uint8List Function(Uint8List bytes, int cap);
