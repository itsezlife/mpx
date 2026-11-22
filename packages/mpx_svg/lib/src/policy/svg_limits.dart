import 'package:meta/meta.dart';

/// How much untrusted SVG a host lets through, and how large it draws.
///
/// A policy value: the host passes it to the decoder (and to the sanitizer
/// and compiler underneath) and every SVG is held to it. [standard] is a safe
/// default for SVG from anywhere; a host that only draws its own bundled art
/// may raise the caps, one that shows SVG from strangers may lower them.
///
/// The caps bound the three ways an SVG can cost more than it looks:
///
/// | Cap | Bounds |
/// | --- | --- |
/// | [maxInputBytes] | parse time and memory of the text itself |
/// | [maxElements], [maxDepth] | the document tree the compiler walks (a deep nest overflows a recursive walk) |
/// | [maxUseExpansion] | `<use>` fan-out: a few kilobytes that reference each other expand to billions of elements |
/// | [maxCompileTime] | whatever slips past the counts: the worker is stopped, not waited for |
/// | [maxPixelEdge] | the raster: a tiny file may declare a huge picture |
@immutable
final class SvgLimits {
  /// Creates limits; every cap must be positive.
  const SvgLimits({
    required this.maxInputBytes,
    required this.maxPixelEdge,
    required this.maxElements,
    required this.maxDepth,
    required this.maxUseExpansion,
    required this.maxCompileTime,
    this.allowEmbeddedImages = false,
    this.compiledCacheBytes = 4 * 1024 * 1024,
  }) : assert(
         maxInputBytes > 0 &&
             maxPixelEdge > 0 &&
             maxElements > 0 &&
             maxDepth > 0 &&
             maxUseExpansion > 0,
         'SvgLimits caps must be positive.',
       ),
       assert(compiledCacheBytes >= 0, 'compiledCacheBytes is not negative.');

  /// A 1 MiB document, drawn at most 4096 px on its long edge, of at most
  /// 100 000 elements nested at most 100 deep, `<use>` expanding to at most
  /// 500 000 elements, compiled within 5 s; no embedded images.
  static const SvgLimits standard = SvgLimits(
    maxInputBytes: 1024 * 1024,
    maxPixelEdge: 4096,
    maxElements: 100000,
    maxDepth: 100,
    maxUseExpansion: 500000,
    maxCompileTime: Duration(seconds: 5),
  );

  /// The largest document, in bytes of its file, that is read at all.
  final int maxInputBytes;

  /// The longest edge, in pixels, the picture is drawn at, whatever the spec
  /// asks.
  final int maxPixelEdge;

  /// The most elements a document may have.
  final int maxElements;

  /// The deepest nesting of elements a document may have.
  final int maxDepth;

  /// The most elements a document may have once every `<use>` is expanded
  /// to the subtree it references.
  final int maxUseExpansion;

  /// How long sanitizing and compiling one document may take before it is
  /// stopped.
  final Duration maxCompileTime;

  /// Whether images embedded as `data:` URIs (PNG, JPEG, WebP, GIF, BMP) are
  /// let through. Off by default: an embedded image is a second decoder's
  /// input, with its own size the caps above do not see. External image
  /// references are never let through.
  final bool allowEmbeddedImages;

  /// How many bytes of compiled documents the decoder keeps, by media key,
  /// so the same SVG at another size skips the parse; 0 keeps none.
  final int compiledCacheBytes;

  /// These limits with the given fields replaced.
  SvgLimits copyWith({
    int? maxInputBytes,
    int? maxPixelEdge,
    int? maxElements,
    int? maxDepth,
    int? maxUseExpansion,
    Duration? maxCompileTime,
    bool? allowEmbeddedImages,
    int? compiledCacheBytes,
  }) => SvgLimits(
    maxInputBytes: maxInputBytes ?? this.maxInputBytes,
    maxPixelEdge: maxPixelEdge ?? this.maxPixelEdge,
    maxElements: maxElements ?? this.maxElements,
    maxDepth: maxDepth ?? this.maxDepth,
    maxUseExpansion: maxUseExpansion ?? this.maxUseExpansion,
    maxCompileTime: maxCompileTime ?? this.maxCompileTime,
    allowEmbeddedImages: allowEmbeddedImages ?? this.allowEmbeddedImages,
    compiledCacheBytes: compiledCacheBytes ?? this.compiledCacheBytes,
  );

  @override
  bool operator ==(Object other) =>
      other is SvgLimits &&
      other.maxInputBytes == maxInputBytes &&
      other.maxPixelEdge == maxPixelEdge &&
      other.maxElements == maxElements &&
      other.maxDepth == maxDepth &&
      other.maxUseExpansion == maxUseExpansion &&
      other.maxCompileTime == maxCompileTime &&
      other.allowEmbeddedImages == allowEmbeddedImages &&
      other.compiledCacheBytes == compiledCacheBytes;

  @override
  int get hashCode => Object.hash(
    maxInputBytes,
    maxPixelEdge,
    maxElements,
    maxDepth,
    maxUseExpansion,
    maxCompileTime,
    allowEmbeddedImages,
    compiledCacheBytes,
  );

  @override
  String toString() =>
      'SvgLimits(input $maxInputBytes B, edge $maxPixelEdge px, '
      '$maxElements elements, depth $maxDepth, use $maxUseExpansion, '
      '${maxCompileTime.inMilliseconds} ms'
      '${allowEmbeddedImages ? ', embedded images' : ''})';
}
