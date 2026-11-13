# ADR 0003: Media core, identity and decoders

`mpx_core` is the product-neutral part of chat_scroll_view's
`catalog_assets`: asset cache, fetch + decode pipeline, playback clock and pause
layers, budgets, visibility, the texture seam and placeholders. It owns media
identity (`MediaKey`, `MediaDescriptor`) and takes in the frame texture plugin
and the engine image decoder. The Lottie and video decoders move with their
shape intact, each joined with its native library in one package. The feed
decision adds three inputs to the core.

**Status**: Accepted (decided with the maintainer 2026-11-10)
**Relates to**: 0001, 0002, 0004, 0005, 0009
**Amended**: 2026-11-13, identity and package folds (ticket 27)

## Context

`catalog_assets` started as the panel catalog's asset cache and became the
media cache for everything. Its chat traces are data, not structure: presets,
budgets, cache scopes, playback policy defaults and placeholders named after
emoji, stickers and panels, a glyph atlas keyed by an emoji catalogue hash, and
the inline embeds. The decoders implement its seams and take
`ContentDescriptor` from `content_model`, which also holds rich text and
collections. The core already has pause layers, priority classes
(placeholder > visible > preload), lane caps, cancel-on-detach and budgets for
unattached entries. A feed needs more (ADR 0005).

## Decision

### Identity

| Area | Decision |
| --- | --- |
| Home | `mpx_core` |
| Types | `MediaKey` (sealed: `remote(id)`, `external(id)`, `local(uuid)`) and `MediaDescriptor` (key, `MediaKind`, animated, `MediaDimensions`, byte size, duration, `MediaThumbnailRef`): the meaning of `ContentKey` / `ContentDescriptor` without the chat variants (Unicode emoji), the pack reference and the panel facts |
| Stable form | `MediaKey.encoded`: `<variant>-<id>`, the id percent-escaped as UTF-8 to `A-Z a-z 0-9 . _ ~ -`, so it is a safe file name and bytes-cache key; `parse` / `tryParse` read it back |
| Local keys | `MediaKey.local(uuid)` names a locally produced file from the start of capture or compression; the bytes cache later aliases the server key to it (ADR 0002, 0007) |
| Users | The core, the decoders, `mpx_player`, `mpx_capture` |
| Stays in chat | `ContentKey`, `ContentDescriptor`, rich text, collections, packs, content library; the chat maps `ContentKey` to `MediaKey` where it builds its stack |

### What moves into the core

| From `catalog_assets` | Fate |
| --- | --- |
| Asset cache, spec, readiness, tiered budgets | Core |
| `AssetPipeline`, `ContentFetcher`, `Decoder`, priority lanes | Core; the core has no networking and no dependency on the bytes cache. `mpx` fills `ContentFetcher` from `http_bytes_cache` |
| Playback clock, `PlaybackPauseLayer`, policy | Core; product-named defaults become host-supplied presets |
| Texture seam (`FrameTextureHost`), frame pool | Core, with the platform texture hosts of `frame_texture` |
| `ContentView`, `AssetCacheProvider`, placeholders | Core |
| Glyph atlas (`src/atlas`, `src/glyph`) | Stays in chat, own package; `AssetCacheScope` has no glyph route (`glyphSource`, `systemFonts`, the glyph placeholder): a host draws glyphs beside the scope |
| Inline and content embeds | Stay in chat |
| Emoji, sticker and panel presets and budgets | Stay in chat; the host passes them in |

Barrels: `mpx_core.dart` (everything above, the texture hosts and the image
decoder), `frame_pool.dart`, `testing.dart`. Bare keys resolve through the
core's own `MediaResolver` seam. Type names already carried no product words;
only the product presets (grid cell, inline, emoji-only, single-emoji
sticker) and their constants left `AssetPresets`.

### Decoders, natives, texture

| Today | Lands in | Fate |
| --- | --- | --- |
| `image_decoder` | `mpx_core` | Moves as is, as a folder of the core |
| `frame_texture` | `mpx_core` | Moves; the core becomes a plugin (`MpxCorePlugin`, Android package `dev.mpx.core`); channel id `dev.mpx.frame_texture`; library `libmpx_frame_texture`, C symbols `mpx_frame_texture_*` |
| `lottie_decoder` + `lottie_native` | `mpx_lottie` | Move into one package with a build hook; worker names lose `chat_`; C ABI, Dart symbols, asset URI renamed to `mpx_lottie_*` / `libmpx_lottie`; the frame cache keeps its files and answers the bytes cache's eviction requests for its registered quota (ADR 0002) |
| `video_decoder` + `video_native` | `mpx_video_decoder` | Move into one package with a build hook; stays the software path for silent inline loops; library, symbols and env var renamed to `libmpx_video`, `mpx_video_*`, `MPX_VIDEO_FFMPEG_DIR`; decode-only |

Native names carry the `mpx` prefix and the owning component, so symbols never
collide across packages and name their owner.

### Core additions from the feed decision

| Addition | Shape |
| --- | --- |
| Visible fraction | A binding reports a fraction, not only visible / hidden. Feeds pick the item in view and gate frame advance (Android floor 0.25) |
| Staged preload | Preload requests carry a stage (metadata, first frame, n seconds), a priority and a cancel; the single `preload` class becomes staged |
| Network and power inputs | Host-fed inputs on the pause layers, like the existing `lowPower`; `mpx`'s device signals are the default source, wired by the stack, never a core dependency |

Implemented as: `AssetBinding.visibleFraction` with a per-surface
`AssetProfile.advanceFloor` (a feed knob passed down, default 0; below it the
binding holds its frame); `AssetCacheScope.preload(key, spec, stage:,
distance:)` with `AssetPreloadStage` `metadata` / `seconds(d)` / `firstFrame`,
read live by producers through `AssetDemand.preloadStage` and `distance`, a
satisfied attempt ending as cancelled; `PlaybackPauseLayer.meteredNetwork` and
`thermalStress` fed through `PlaybackActivity`, outside the standard pausing
set, which together with `lowPower` and `fastScroll` hold back new staged
preload attempts (`AssetCacheScope.preloadPausingLayers`).

### Shared playback phase

The same content at two specs is two cache entries, each with its own
playback. The entries of one `MediaKey` that play at once share their phase:
the scope keeps an `AssetPlaybackPhase` per key and passes it in the paint
context (`AssetPaintContext.phase`). A playing paintable reports how far into
its pass it is at each paint that steps it; at its first such paint, and at
one after the clock ran on without it (drawn over), it takes the position
another entry reported. A playback stopped on purpose (held, hidden, off
screen) and a rewound one (a foreground surface) go on from their own frame.
The position runs on with the clock while its entry plays and stays where it
stopped once it does not. Lottie renders any frame, so it is there at once;
the image codec and the video decoder decode forward only, so they decode and
drop the frames up to it while the frame on show stays. A playing sibling
lends its live playback to a binding below its first frame; a foreground
binding gets the first-frame still, as before.

### Unchanged contracts

The fetch contract stands: settle promptly on cancel, report progress at start
and per chunk to every sharer, answer `needsDownload` at once. Readiness never
shows a failure stage. The HW player's textures live outside the CPU texture
pool and its budget (ADR 0004).

## Why

- The emoji and panel traces are presets. Pulling the presets out leaves a core
  any host can use, without renaming its structure.
- A core-owned key breaks the `content_model` coupling without a package of
  its own; taking `content_model` would drag rich text into every media host,
  and sharing `ContentKey` would put chat variants in the portable set.
- Frame textures and the image decoder are small and every decoding host needs
  them; a decoder and its native library change together. Neither split saved
  a host a dependency (ADR 0001).
- The decoders already speak only the core's seams; moving them unchanged keeps
  their tests as the migration's safety net.
- The feed's three gaps belong in the core because list cells, pager pages and
  the viewer all bind through it.

## Rejected

| Alternative | Why not |
| --- | --- |
| Keep `catalog_assets` whole and rename it | Ships the glyph atlas and embeds to every host |
| `content_model` as a portable package | Too much chat domain |
| An identity leaf shared with `content_model` | A package of its own for a key with chat variants |
| Keeping `image_decoder`, `frame_texture` and the native libraries as packages | Publish overhead; no host takes one side without the other |
| Velocity-driven preload class in the core | Feed decision: velocity only stretches cheap stages (ADR 0005) |
| The core depending on `http_bytes_cache` | Pulls networking into the core; hosts with their own fetcher pay for it |
| A plain `mpx_` ABI prefix for every native | Symbols of two packages could collide and would not name their owner |

## Consequences

- Each chat host now passes its presets and budgets explicitly.
- The chat maps `ContentKey` to `MediaKey`; `content_model` takes no mpx
  dependency.
- `mpx_core` is a plugin.
- The glyph atlas needs its own package in the chat repo, depending on the core.
- Native ABI and asset-id renames break any binary built before the move, so
  they happen once, before prebuilts publish (ADR 0009).
- Bindings and the pipeline gain API; tests in the core's contract suites grow
  with them.

## Open in implementation

- Where a default preset table for a host without its own lives, if any
  (`mpx`'s factory is a candidate); the core keeps only the generic
  `AssetPresets.square` and `AssetPresets.media` recipes.

## Provenance

Planning tickets `07`, `08`, `10`, `13`, `18` (no core to cache edge),
`19` (frame quota), `21` (signals source), `23` (local key), `24` (native
names), `27` (folds, core-owned key); research
`07-current-inventory` (package table, edges),
`05-feed-policies.md` §6 (what the core has and lacks). chat_scroll_view ADRs
020, 022, 042, 043.

## Related

ADR 0002 (bytes under the fetch seam through `mpx`), 0005 (feed uses the additions), 0009
(the split during the move).
