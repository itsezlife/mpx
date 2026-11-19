# ADR 0001: Package topology of mpx

mpx is a pub workspace of nine packages: seven under the `mpx_` prefix, the
bytes cache `http_bytes_cache`, and the umbrella `mpx`. A package boundary
stands only where a host would otherwise pay for what it does not use: heavy
native code, platform permissions, or a standalone pure-Dart library. Logical
layers are folders inside a package. Native code lives in the package that
uses it. The umbrella is a composition root that re-exports nothing.

**Status**: Accepted (decided with the maintainer 2026-11-10; package set
reduced from eighteen to eight on 2026-11-13; `mpx_library` added by ADR 0011
on 2026-11-20)
**Relates to**: 0002, 0003, 0004, 0005, 0006, 0007, 0008, 0009, 0011

## Context

Media code lives in chat_scroll_view today: `catalog_assets` (about 16k lines,
209 declarations), three decoders, two native leaves and `frame_texture`. All
of them are close to product-neutral. The chat traces are a `chat_` prefix in
native symbols and channel ids, the presets and budgets named after emoji,
stickers and panels, the glyph atlas and the embeds. A separate bytes cache,
image_bytes_cache, lives in its own repository. The map asks for one media
monorepo that any app can use, with image_bytes_cache moved in, and the chat as
a consumer. Two package names (`lottie_native`, `player`) are taken on pub.dev,
so the set needs a prefix.

A first cut gave every logical layer its own package (identity, fetch adapter,
frame texture, each decoder, each native library, player and player backends,
feed, viewer, capture and capture backends, device signals): eighteen in all.
Most of those boundaries cost the host nothing to cross, so they bought
version and publish overhead without saving any host a dependency.

## Decision

### Packages

| Package | Kind | Owns |
| --- | --- | --- |
| `http_bytes_cache` | Dart + native reader | Whole and ranged resources, one disk store with named quotas, HTTP middlewares, the native reader of ranged resources (ADR 0002) |
| `mpx_core` | Plugin | `MediaKey`, `MediaDescriptor`; asset cache, pipeline, playback clock and pause layers, budgets, visibility, texture seam and the platform texture hosts, placeholders, the engine image decoder (ADR 0003) |
| `mpx_lottie` | Flutter + build hook | Vector animation `Decoder`, frame cache, Rust library over tlottie |
| `mpx_video_decoder` | Flutter + build hook | Software video `Decoder` for silent loops, FFmpeg + libvpx library, decode-only |
| `mpx_player` | Plugin | Player pool, leases, audio owner (ADR 0004); Media3 ExoPlayer and AVPlayer backends reading through the bytes cache's native reader; feed modes, knobs and preload staging (ADR 0005) |
| `mpx_ui` | Flutter, optional | Fullscreen viewer with its own tokens (ADR 0006); feed list and pager widgets (ADR 0005) |
| `mpx_library` | Plugin, optional | The device media library (access, albums, paged assets, changes, originals) and the file intake (system file dialog, system camera, drop, paste); library keys and their fetcher (ADR 0011) |
| `mpx_capture` | Plugin, optional | Compression, still preparation, the camera session and round video; CameraX, Media3 Transformer, MediaCodec and AVFoundation capture code (ADR 0007, 0011) |
| `mpx` | Plugin | Composition root `MpxStack.create(...)`; the `ContentFetcher` adapter `BytesCacheFetcher` over `http_bytes_cache`; device signals (network class, power saving, thermal status); the set's README and example app |

### Dependency direction

Arrows point at the dependency.

```
mpx_lottie         -> mpx_core
mpx_video_decoder  -> mpx_core
mpx_player         -> mpx_core, http_bytes_cache
mpx_library        -> mpx_core
mpx_ui             -> mpx_player, mpx_core, mpx_library
mpx_capture        -> mpx_core, http_bytes_cache
mpx                -> mpx_core, http_bytes_cache
```

`mpx_core` and `http_bytes_cache` never depend on each other; `mpx` joins
them. `mpx` never depends on `mpx_lottie`, `mpx_video_decoder`, `mpx_player`,
`mpx_ui`, `mpx_library` or `mpx_capture`: the host passes decoders into the stack and wires
the optional packages itself, so taking `mpx` never links FFmpeg, Media3 or
camera code.

### When a package boundary stands

| Reason | Packages it separates |
| --- | --- |
| Heavy native code a host may not want | `mpx_lottie` (Rust), `mpx_video_decoder` (FFmpeg), `mpx_player` (Media3) |
| Platform permissions | `mpx_capture` (camera, microphone), `mpx_library` (photo library, the camera through the system camera intent) |
| A standalone pure-Dart library with value outside media | `http_bytes_cache` |
| Large optional UI | `mpx_ui` |
| Wiring that would otherwise force an edge between two of the above | `mpx` |

Anything else is a folder under `lib/src/`. A new package needs one of these
reasons.

### What stays in chat_scroll_view

| Stays | Note |
| --- | --- |
| `content_model` | Rich text, collections, packs, library, `ContentKey` and `ContentDescriptor`; stays pure Dart and takes no mpx dependency |
| `ContentKey` to `MediaKey` mapping | Chat-side, where the chat builds its stack |
| Glyph atlas | Emoji-specific; its own chat-side package |
| Inline and content embeds | Message-text concerns |
| Emoji, sticker and panel presets and budgets | Hosts supply presets to the core |
| `chrome_foundation` | The viewer takes tokens from the host instead |

### Rules

| Rule | Detail |
| --- | --- |
| No re-exports | A package never re-exports another package's API; `mpx` is no exception |
| Fakes | Exported only from `testing.dart`; `flutter_test` stays a regular dependency |
| Native code | Lives in the package whose Dart code calls it; plugins are single, not federated; a plugin may also carry a build hook |
| Native names | C symbols, libraries, asset ids, channel ids and env vars start with `mpx_` / `dev.mpx.` / `MPX_` and the component that owns them (ADR 0009) |
| Optional layers | `mpx_ui`, `mpx_library` and `mpx_capture` are opt-in; nothing below imports them (`mpx_ui` takes `mpx_library` for its library grid) |
| Identity | Media is keyed by `MediaKey`, never by URL |

## Why

- Splitting by host cost rather than by layer is how media libraries on
  pub.dev split (a core plus one package per heavy native dependency). A layer
  boundary inside one package is still enforced by imports and tests.
- The core owns its key so the portable set takes nothing from the chat:
  `content_model` is pure Dart and cannot depend on a Flutter core, and its
  `ContentKey` carries chat variants (Unicode emoji). Mapping one key to the
  other at the chat's composition point is a few lines.
- The frame texture hosts and the engine image decoder are small and every
  host that decodes needs them; folding them into the core makes the core a
  plugin and saves two packages.
- A decoder and its native library change together; one package means one
  version and one release.
- Feed policies are rules over the player pool (prepared budget, sound owner,
  preload stages), so they live with the pool; the widgets that draw a feed
  belong with the viewer as optional UI.
- One bytes cache for every kind gives one eviction and one budget. All three
  reference clients keep streamed video and small media in one store.
- The player sits over the core so it shares the clock, pause layers, budgets
  and visibility the decoders already use, instead of growing a second set.
- The player depends on the cache directly because the cache owns the ranged
  resource and its native reader end to end; a seam through the core would add
  a hop on the hot read path for no second implementer.
- `mpx` holds the fetch adapter and the device signals because both are wiring
  between packages that must not know each other. A host with its own fetcher
  and its own signals uses the core without `mpx`.
- The viewer taking its own tokens keeps `chrome_foundation` and its chat
  palette out of a portable package.
- `http_bytes_cache` drops the prefix because it caches any HTTP bytes and is
  useful outside media.

## Rejected

| Alternative | Why not |
| --- | --- |
| One package per logical layer (eighteen packages) | Version and publish overhead with no host saving a dependency |
| An identity leaf shared with `content_model` | A ninth package to keep a chat key with chat variants in the portable set |
| `content_model` as part of the portable set | Drags rich text, collections, packs and library into every media host |
| Separate native packages beside their decoders | They change and release together; no host takes one without the other |
| One `mpx_video` package with the software decoder and the player | A host with silent loops only would link Media3; a host with the player only would link FFmpeg |
| Feed policies and widgets in one package | Splits the pool's budget rules from the pool, or puts widgets under the player |
| A second cache for streamed video | Two budgets, two evictions, two network stacks |
| Platform media caches (Media3 `SimpleCache`) | Owns its folder and deletes foreign files; no HTTP validation |
| Federated plugins | Two to four packages each with no outside platform maintainers |
| Moving the glyph atlas to mpx | Keyed by emoji catalogue; no other consumer |
| Viewer depending on `chrome_foundation` | Couples a portable package to the chat's theme |
| Fetch adapter in the core or in the cache | Puts networking in the core, or a core dependency in a standalone cache |
| Player reaching the ranged store through the core's fetch seam | The read path is native and blocking; the fetch seam is whole-resource Dart |
| `mpx` depending on the decoders and the player | Every host using the root links FFmpeg and Media3 |
| Umbrella that re-exports the set | Breaks the no-re-export rule for one convenience |

## Consequences

- `catalog_assets` splits three ways (core, glyph atlas, chat presets and
  embeds); its name goes away.
- `content_model` keeps its key; the chat maps `ContentKey` to `MediaKey` where
  it composes its stack.
- `mpx_core` is a plugin, so a pure-Dart host cannot use it; that was already
  true of the Flutter core.
- The native ABI, asset ids, channel ids, worker names and env vars change
  once, during the move (ADR 0009).
- Hosts either compose the stack themselves or call `mpx`'s factory with the
  decoders they want; either way they import the packages whose types they
  use.
- `mpx` is a plugin because it carries the device signals.
- This diverges from chat_scroll_view ADR 020's rule that native code sits in
  leaf packages.

## Settled in implementation

- Names: `MpxStack` (composition root) and `BytesCacheFetcher` (fetch
  adapter). The host names URLs through a `MediaLocator`; heavy decoders come
  from an `MpxDecoderFactory` built over the stack's clock and textures, so
  `mpx` keeps no edge to them. The example app depends on the decoders: it
  shows the set, it is not part of `mpx`.

## Open in implementation

- Whether `mpx_video_decoder` takes a shorter name.

## Provenance

Planning tickets `07`, `08`, `14` (with the `http_bytes_cache` addendum),
`15`, `17` (player edge), `18` (fetch adapter), `20` (umbrella), `21` (device
signals), `24` (native names), `27` (fewer packages); research
`07-current-inventory`, `15-pub-facts.md`. chat_scroll_view
ADR 020 (topology) and its native-leaf rule.

## Related

ADR 0002 (bytes cache), 0003 (core and decoders), 0009 (migration), 0011
(library, intake, preparation and picking).
