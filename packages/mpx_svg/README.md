# mpx_svg

An SVG decoder for `mpx_core`. It sanitizes untrusted SVG within host limits,
compiles it off the UI isolate and draws it at the size a surface asks for.
The content views that draw any media then draw SVG too: the same sources,
readiness stages, budgets and placeholder.

## Install

Not published yet. Depend on it from git:

```yaml
dependencies:
  mpx_svg:
    git:
      url: https://github.com/itsezlife/mpx.git
      path: packages/mpx_svg
```

## Usage

Register the decoder for vector images, and describe SVG content with that
kind:

```dart
import 'package:mpx/mpx.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_svg/mpx_svg.dart';

final stack = await MpxStack.create(
  locate: (descriptor, part) => MediaLocation(urlOf(descriptor.key)),
  decoders: (context) => {MediaKind.vectorImage: SvgDecoder()},
);
stack.pipeline.know(
  const MediaDescriptor(
    key: MediaKey.external('https://example.com/logo.svg'),
    kind: MediaKind.vectorImage,
  ),
);

// Anywhere below an AssetCacheProvider:
ContentView(
  content: const MediaKey.external('https://example.com/logo.svg'),
  preset: AssetPresets.square(
    extent: 48,
    devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
    profile: const AssetProfile(),
  ),
);
```

For a one-colour icon, pass `decodeMode: AssetDecodeMode.template` to the
preset and a `tint` to the view. The icon is then one cache entry in every
colour.

## Features

- **Safe for untrusted input.** `SvgSanitizer` rejects the whole document,
  without stripping parts, when it finds:
  - scripts, embedded documents or SMIL animation;
  - event handlers;
  - references out of the document;
  - CSS that imports or animates;
  - entity declarations;
  - too many elements, too deep a nesting, or a `<use>` fan-out over the cap.
- **Host limits.** `SvgLimits` is a policy value. `SvgLimits.standard` is
  1 MiB of input, a 4096 px long edge and a 5 s compile, and its fields are
  open.
- **Off the UI isolate.** `SvgCompiler` runs each compile on a worker. A
  compile past the time cap or cancelled has its worker ended. The web runs it
  in place.
- **Sharp at every size.** The picture is drawn into the spec's pixels, and
  the compiled form is kept per media key, so another size skips the parse.
- **Fails like a still.** A refused document is a permanent failure, so the
  surface keeps its placeholder.

## Docs

ADR 0003 (media core and decoders) and ADR 0001 (why it is a package of its
own) in the repository's `docs/adr/`.
