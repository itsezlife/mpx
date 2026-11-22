import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:mpx_core/src/image/image_head_file_web.dart'
    if (dart.library.io) 'package:mpx_core/src/image/image_head_file_io.dart';
import 'package:mpx_core/src/pipeline/content_fetcher.dart';

/// The first bytes of fetched content, and what they say it is.
abstract final class ImageHead {
  /// How many bytes are read: enough for a declaration, a comment and a
  /// document type before an SVG root.
  static const int length = 1024;

  /// The first [length] bytes of [content], or null where they cannot be
  /// read (a ranged resource, a file on the web, a file that is gone).
  static Future<Uint8List?> read(FetchedContent content) => switch (content) {
    FetchedBytes(:final bytes) => SynchronousFuture(
      bytes.length <= length ? bytes : Uint8List.sublistView(bytes, 0, length),
    ),
    FetchedFile(:final path) => readFileHead(path, length),
    FetchedRanged() => SynchronousFuture(null),
  };

  /// Whether [head] starts an SVG document: after an optional byte-order
  /// mark, XML declaration, comments and document type, the root is `svg`.
  /// A page that merely contains an SVG (HTML) is not one.
  static bool isSvg(Uint8List head) => _svgRoot.hasMatch(latin1.decode(head));

  static final RegExp _svgRoot = RegExp(
    r'^(\xEF\xBB\xBF)?\s*(<\?xml[^>]*\?>\s*)?'
    r'((<!--[\s\S]*?-->|<!DOCTYPE[^\[>]*(\[[\s\S]*?\])?\s*>)\s*)*'
    r'<svg[\s>/]',
    caseSensitive: false,
  );
}
