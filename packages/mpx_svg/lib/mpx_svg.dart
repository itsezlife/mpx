/// SVG for mpx: a decoder that draws SVG documents as stills of the asset
/// cache, held to a host policy for untrusted input.
///
/// A host registers `SvgDecoder` under `MediaKind.vectorImage`; the content
/// views that draw any media then draw SVG, at the size they ask for. The
/// policy (`SvgLimits`) and the checks under it (`SvgSanitizer`,
/// `SvgCompiler`) need no widget and run on their own.
library;

export 'src/compile/svg_compiler.dart'
    show
        SvgCompilation,
        SvgCompiler,
        SvgSource,
        SvgSource$Bytes,
        SvgSource$File;
export 'src/decoder/svg_decoder.dart';
export 'src/policy/svg_limits.dart';
export 'src/policy/svg_sanitizer.dart';
