# ADR 0009: Migration from chat_scroll_view

The media packages leave chat_scroll_view for mpx in five ordered steps. The
native-media branch merges first. The hooks move to 2.x. mpx is created with
history and every name changes once, during the move. image_bytes_cache joins
as the bytes cache. chat_scroll_view then switches to git dependencies on mpx
and deletes its copies. Each step leaves both repositories green, and no
parallel copy lives on.

**Status**: Accepted (decided with the maintainer 2026-11-10)
**Relates to**: 0001, 0002, 0003, 0008

## Context

The media code sits on chat_scroll_view's `feat/native-media-ffi` branch (PR
#88): `catalog_assets`, `image_decoder`, `lottie_decoder`, `lottie_native`,
`video_decoder`, `video_native` and `frame_texture`, with ADRs 020, 022, 042,
043 and 044. image_bytes_cache lives in its own repository. The native packages
carry a `chat_` prefix in their C ABI, asset URIs, worker names and an env var;
`frame_texture` carries `chatscrollview` in its channel and Android package id.
Renaming the ABI breaks every binary built before it, so it should happen once,
before prebuilts publish.

## Decision

### Order

| Step | Action | Green check |
| --- | --- | --- |
| 1 | Finish and merge `feat/native-media-ffi` (PR #88) into chat_scroll_view master | chat repo |
| 2 | Prefix fixed (`mpx_`, ADR 0008); bump `hooks` / `code_assets` to 2.x | chat repo |
| 3 | Create mpx with history (subtree split) and rename everything once | mpx |
| 4 | Bring image_bytes_cache in as `http_bytes_cache`; its gaps become follow-up tickets (ADR 0002) | mpx |
| 5 | chat_scroll_view takes git dependencies on mpx, moves to the new names in one change, deletes its copies | both |

Pub dependencies replace git dependencies once the packages publish.

### What step 3 moves and renames

| Source | Destination | Renames |
| --- | --- | --- |
| `catalog_assets` (core part) | `mpx_core` | package; product-named defaults become host presets; new `MediaKey` / `MediaDescriptor` modelled on `content_model`'s key and descriptor |
| `image_decoder` | `mpx_core` | package; becomes a folder of the core |
| `frame_texture` | `mpx_core` | channel id, Android package id; the core becomes a plugin |
| `lottie_decoder` + `lottie_native` | `mpx_lottie` | one package; worker strings, C ABI, Dart symbols, asset ids, library name |
| `video_decoder` + `video_native` | `mpx_video_decoder` | one package; worker strings, C ABI, Dart symbols, asset ids, library name, env var |

No `chat_` remains in any native ABI, channel id or environment variable. The
new native names carry the `mpx` prefix and the owning component:

| Kind | New name |
| --- | --- |
| Lottie C symbols, library | `mpx_lottie_*`, `libmpx_lottie` |
| Video C symbols, library | `mpx_video_*`, `libmpx_video` |
| Channel ids | `dev.mpx.<component>`, e.g. `dev.mpx.frame_texture` |
| Env vars | `MPX_<COMPONENT>_*`, e.g. `MPX_VIDEO_FFMPEG_DIR` |
| Bytes cache native reader | `http_bytes_cache_*`, short `hbc_*` for C symbols (new code, no rename) |

### What stays in chat_scroll_view

| Stays | Becomes |
| --- | --- |
| `content_model` whole, `ContentKey` and `ContentDescriptor` included | Unchanged; pure Dart, no mpx dependency |
| `ContentKey` to `MediaKey` mapping | Chat-side, where the chat builds its stack |
| Glyph atlas from `catalog_assets` | Its own chat-side package over `mpx_core` |
| Inline and content embeds | Chat-side |
| Emoji, sticker and panel presets and budgets | Chat-side, passed to the core by the host |
| `chrome_foundation`, panel packages, composer, viewport | Unchanged |

### Rules during the move

| Rule | Detail |
| --- | --- |
| History | Subtree split keeps each package's history, including the packages folded into another |
| One rename | Final names in one pass; the chat moves straight to them |
| No parallel copies | Once step 5 lands, the chat holds no copy of a moved package |

## Why

- Merging PR #88 first means the move starts from one tree, not a branch that
  keeps changing under the split.
- One rename, before prebuilts, breaks ABI and asset ids exactly once; renaming
  after the move would break the chat twice.
- Each step green in both repos keeps the chat shippable throughout.
- Git dependencies let the chat consume mpx before any pub release.

## Rejected

| Alternative | Why not |
| --- | --- |
| Copy without history | Loses blame for 16k lines of core |
| Move first, rename later | Two breaking changes for the chat and for any binary |
| Keep both copies while mpx matures | Divergence; fixes land twice |
| Moving `content_model` whole | Takes rich text and packs into the media repo |
| Moving `ContentKey` into a shared identity package | A ninth package for a key with chat variants (ADR 0001) |
| Waiting for pub releases before the chat switches | Blocks the chat on publishing and LGPL review |

## Consequences

- chat_scroll_view's workspace loses six packages (`image_decoder`, `lottie_decoder`, `lottie_native`, `video_decoder`, `video_native`, `frame_texture`) and the core part of `catalog_assets`, and gains git dependencies;
  its lints and test entrypoint lose the moved packages.
- The example's media composition (`app_services.dart`, playback wiring, disk
  caches) moves onto the new names and, later, onto the bytes cache adapter.
- Every host that built native libraries locally rebuilds after the ABI rename.
- The chat's ADR 022 rule that the Lottie frame and glyph tiers keep no budget
  of their own is replaced: they count against named quotas in the bytes
  cache (ADR 0002).

## Open in implementation

- The glyph atlas package's name and its place in the chat's topology ADR.
- What happens to the chat's media ADRs (022, 042, 043 and the media parts of
  020 and 044) once mpx ADRs hold the decisions.
- Git dependency refs: tag, branch or commit pinning while mpx is pre-release.
- Whether chat_scroll_view's lints keep checking moved packages' rules through
  mpx's own lints instead.

## Provenance

Planning tickets `07`, `08`, `13`, `14`, `24` (native names), `27` (folds); research
`07-current-inventory`.

## Related

ADR 0001 (target topology), 0002 (bytes cache gaps after step 4), 0008 (prefix,
hooks bump).
