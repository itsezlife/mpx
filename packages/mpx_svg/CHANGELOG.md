# Changelog

## Unreleased

- Registered as the still kind's fallback, `SvgDecoder` draws SVG the host
  described as a plain image.
- `SvgDecoder`: draws SVG as stills of the asset cache under
  `MediaKind.vectorImage`. The picture covers the spec and the view places
  it by its fit; its long edge is capped, and template specs are tinted at
  paint. Compiled forms are kept per media key, and a refusal is a
  permanent failure.
- `SvgSanitizer` and `SvgLimits`: a host policy for untrusted SVG. Scripts,
  embedded documents, animation, event handlers, external references,
  importing CSS, entities and oversized trees are refused, never stripped.
- `SvgCompiler`: compiles on a worker isolate, which is ended on cancel and
  past the time cap.
