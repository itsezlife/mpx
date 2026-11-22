# ADR 0010: Loading stages

A media item is drawn in stages from the first frame it is on screen:
nothing (clear), a preview, a thumbnail, the content. Each rise is a fade
or a swap set per platform. A status control and a badge over it show the
transfer. A host policy decides which content downloads by itself. A
failure keeps the picture and turns the control back to download.

**Status**: Accepted (decided with the maintainer 2026-11-17)
**Relates to**: 0002, 0003, 0004, 0005, 0006

## Context

Until now readiness had four stages (`none`, `placeholder`, `firstFrame`,
`full`), and `placeholder` meant a fetched thumbnail. The first paint after
an attach was the scope's default placeholder, a light flat box, until that
thumbnail arrived over the network. No reference client draws such a box:
photos and videos show a blurred inline thumbnail from the first frame (or
nothing, or black), stickers and emoji show an outline of their shape. A
bare progress arc had no download, cancel or retry state, every attach
fetched, and a failure left the arc on.

## Decision

### Stages

`AssetStage` is `none`, `preview`, `placeholder`, `firstFrame`, `full`.

| Stage | Drawn from |
| --- | --- |
| `none` | Nothing: the scope's default placeholder (`ClearPlaceholder`) paints nothing. A host may pass a tinted fill per surface (`RectPlaceholder` with a tint) |
| `preview` | Bytes known without fetching the content or its thumbnail: `MediaDescriptor.preview` (a sealed `MediaPreview`: `raster(encoded)`, a tiny image, or `outline(pathData, viewBox)`, a vector shape), else a **derived preview** the cache stored the first time the content loaded |
| `placeholder` | The fetched thumbnail (`MediaDescriptor.thumbnail`), blurred when its long edge is below the platform's threshold (`ThumbnailBlurRule`) |
| `firstFrame`, `full` | The content |

- A host expands its wire formats (a header-stripped JPEG, a compressed
  path) before they reach the descriptor; the core takes only an encoded
  image or SVG path data.
- A derived preview is the content's first drawable frame, scaled to at most
  40 px on its long edge, PNG-encoded and stored **unblurred** under the
  bytes cache's `previews` quota (`PreviewStore`), then blurred at decode.
- Blur is a decode-time setting of the pipeline (`PreviewBlur`: passes of
  max edge and radius, `forPlatform`), chosen once per stack, so one decoded
  preview serves every surface of the scope. A paint-time overlay (a dark
  wash) belongs to the stage style.
- The pipeline keeps decoded previews in an LRU, so a re-attach draws the
  preview in the attach frame. A preview uses no fetch slot.
- `MediaDescriptor.streamable` says the content can play before it is
  whole.

### Stand-ins under content

- The entry keeps the stand-in each rise replaced (preview, then thumbnail),
  so a binding fades from the stand-in it last showed.
- An outline's shimmer is one band across the screen (amended 2026-11-22).
  Every outline reads the scope's clock, so all share one phase. The surface
  passes the screen, in its paint's coordinates, as the span the band crosses
  (`OutlineLook.sweep`), so outlines side by side each draw their part of one
  band, not a band each.
- A raster stand-in stays opaque under content that fades in. An outline, or
  a stand-in under content that may be transparent, fades out as the content
  rises.
- A surface's own placeholder may outrank stand-in stages up to a stage it
  names (`ContentView.placeholderUntil`). Content rises over it as over a
  raster stand-in: the placeholder and the kept stand-in beneath it stay
  opaque while the content fades in, so a cross-fade never lets the
  background through.
- Transitions are style values per platform (`MediaStageStyle`): a fade of a
  set length, a scale-in, or a hard swap (0 ms). A stage that arrives within
  the attach frame (a memory hit) is drawn without a fade.
- A round surface (a round video; `AssetPresets.round`) draws its stand-ins
  enlarged inside its circle (`MediaStageStyle.roundPreviewScale`), its
  control at the round size, and an optional fill in the host's colour
  under everything until the content has faded in (`ContentView.underlay`).

### Transfer

A binding reports `AssetTransfer`, sealed:

| State | Meaning |
| --- | --- |
| `none` | Nothing to transfer (cached, or in memory) |
| `waiting(total?)` | Known missing; no byte yet |
| `receiving(received, total?)` | Bytes received of a total, else the descriptor's byte size |
| `awaitingUser(total?)` | Not auto-downloaded; waits for `download()` |
| `failed(kind, received, total?)` | The last attempt failed |

- `AssetBinding.descriptor` is null until the descriptor is known (producer
  side `AssetProgress.describe`); `AssetCacheScope.know(descriptor)` hands a
  descriptor to the producer before an attach.
- `AssetBinding.download()` fetches now and clears a cancel.
  `cancelDownload()` stops the content fetch, keeps the stages and is
  remembered per key by the scope for the session, so re-attaching after a
  cancel shows the download control.
- Byte reports reach listeners at most once per frame.

### One transfer per content

The transfer belongs to the content, not to an entry: every spec of a key
(a tile, a list item, a viewer page) shows the same one. The scope keeps
one record per `MediaKey` and derives the transfer there, from:

| Input | Held as |
| --- | --- |
| The user's intent | `none`, `requested` (`download()`), `cancelled` (`cancelDownload()`) |
| The content's entries | What each entry's attempt last reported (waiting, receiving, awaiting, failed) |
| The high-water mark | The most bytes any report gave, until the content is whole |
| Bytes held outside an attempt | Each reader outside the cache, and each spec whose attempt finished while its content still streams |
| The policy's answer | Kept per content until the policy, the attached tags or the descriptor change |

- One download runs per content. A spec attached while another downloads
  is answered `manual` and waits, showing that download; once the content
  is local the waiting specs start again and read it. A policy change
  starts one spec per content.
- An entry that is final for its spec shows no transfer, except a failed
  rest of its streamed content (below), which is its retry.
- The surfaces show at least the mark: a download a surface comes back to
  is drawn where it got to, and content awaiting the user after a stopped
  download shows the bytes it left (`awaitingUser(total, received)`).
- A record that no entry or reader holds keeps the user's intent for the
  scope's life and its mark for the last 256 such contents; the rest goes
  with the last entry.

### Who asks for a download

- **The policy** for the tags attached (above).
- **A surface that requests its content while it shows it**
  (`AssetBinding.requestsDownload`, `ContentView.requestsDownload`: a
  viewer page the user opened). It downloads whatever the policy says, but
  it is not the user's download: when the surface goes or stops asking, a
  download nothing else wants stops where it is, its bytes kept, and the
  content awaits the user.
- **The user** (`download()`): the whole content (`AssetDemand.downloadRequested`,
  `FetchRequest.whole`: a fetcher that streams content as it plays fetches
  the rest behind the reads). It goes on with no surface attached, the
  entry pinned meanwhile, until the content is whole, the user cancels or
  it fails. A viewer closed on it leaves it running.
- **The user's cancel wins** over a requesting surface and the policy.

### Streamed content and readers outside the cache

- Content handed out while it still arrives (`FetchedRanged`) can be final
  for its spec (its first frame) before all its bytes are here. Its attempt
  goes on reporting the bytes its paintable pulls, and a failure of the
  rest a user's download fetches (`FetchedRanged.rest`), after the final
  stage (`AssetProgress` contract). They count for the content only: its
  completion reaches every spec, and a failed rest shows as the content's
  failed transfer, whose `download()` fetches again.
- A reader outside the cache (a platform player streaming the content)
  holds a lease, `AssetCacheScope.openOutsideReader(key)`, that it reports
  its bytes to and closes when it lets the content go; readers count. Their
  bytes are the download while someone wants the content (the user, a
  requesting surface, the policy) and no spec downloads it; otherwise they
  are bytes received over the download control. Bytes a finished attempt
  streams count as the download only for the user's download. All of the
  bytes complete the content.

### Auto-download

- `AutoDownloadPolicy.decide(descriptor, context)` answers `now`, `prefix`
  (a playable head only) or `manual`. The context (`AutoDownloadContext`) is
  an opaque host tag per attach that the core uses only as a key; it never
  enters the cache key. An entry downloads when any attached surface's tag
  allows it.
- A change of the policy (`changes`), or an attach with another tag,
  restarts a waiting entry whose answer became `now`, one per content.
- The core default is `AutoDownloadPolicy.always`. The composition root's
  default (`NetworkAutoDownloadPolicy` in `mpx`) weighs the network class
  and per-kind size limits, with each platform's reference values.

### Status control and badge

- Core widgets driven by plain values: `MediaStatusControl` takes a
  `MediaStatus` (an icon, `MediaStatusIcon` none / download / cancel / play /
  pause, and a progress), and `MediaStatusControl.binding` maps a binding to
  it. `ContentStatusOverlay` lays a binding's control and badge over any
  picture, as `ContentView` does; `MediaStatusPainting` draws the control's
  disc, progress arc and spinner on a canvas, for a leaf that paints its
  own cells. `MediaBadge` shows the duration (or "GIF") and, while receiving,
  "received / total".
- Their style is a per-platform value (`MediaLoadingStyle`: `stages`,
  `status`, `badge`; `$Android`, `$IOS`, `$Desktop`, `forPlatform`,
  `copyWith`) with a scope (`MediaLoadingStyleScope`), resolved from the
  theme's platform as the viewer policy is. A host may replace the control
  (`MediaStatusBuilder`).

### Failure

Readiness never shows a failure stage. The transfer does: `failed` turns the
control back to download, which is the retry. No failed picture is ever
drawn; the leaf keeps the best stage it reached.

### Stills the software path cannot decode

A decoder that cannot read a codec says so (`DecodeFailure.unsupported`),
and the pipeline tries the fallback registered for the kind
(`DecoderRegistry.registerFallback`), with the content fetched again. The
player package provides a platform still extractor (`PlatformStillDecoder`)
that the host registers; it reads through the bytes cache's native reader
or a cached file, never bytes in memory. A fallback that draws only a still
ends the entry at its first frame, final for the spec
(`AssetProgress.bestReached`). Its frame becomes a derived preview, and
content with a stored derived preview is not handed to the extractor
again, so the cost is paid once per item.

## Why

- The reference clients draw no box before content: a blurred inline
  thumbnail, or a shape outline, is there from the first frame.
- One transfer per content, derived in one place, so the cell, the feed
  and the viewer agree whatever spec each decodes, and no two of them
  download the same bytes.
- A user's download is an intent about the content, not about a surface:
  it outlives the surface that asked, and a cancel is the last word.
- Policies are values so they can be tested and so a host can choose
  another platform's feel.

## Rejected

| Alternative | Why not |
| --- | --- |
| A wire-format codec seam in the core | The host expands its own formats before the descriptor |
| Blur resolved per widget | One decoded preview serves every surface of the scope |
| A failed picture or error glyph | No reference draws one; the control carries the retry |
| Keeping the inline stand-in in `placeholder` | Loses the preview → thumbnail fade and "has a preview" |
| Auto-download rules in the core | The network class lives in the composition root |
| A transfer per entry, reconciled across specs | Two specs downloaded the same bytes, and a cancel or a completion reached one spec only |
| Reader bytes as two calls (`report`, `end`) by key | Two players of one content ended each other's account; a lease per reader counts them |

## Consequences

- Every comparison over `AssetStage` is audited when `preview` lands; an
  `index <= placeholder` comparison already counts it as a stand-in.
- `AssetBinding.downloadProgress` gives way to `transfer`;
  `ContentView.loadingRadius` gives way to a status mode.
- `http_bytes_cache` gains a `previews` quota (4 MiB).
- Hosts that wire the core themselves keep today's download behaviour.

## Open in implementation

- A web style and policy of its own.
- Linux: the still extractor over FFmpeg hardware decode behind the same
  fallback seam. Engines keep an injected clock, and no file is loaded
  whole (ADR 0004).

## Provenance

The media-loading-stages spec and its research note on loading stages
across the reference clients (stages per kind, transitions, progress UI,
auto-download, failure), in chat_scroll_view's local scratch area.

## Related

ADR 0002 (the `previews` quota, the native reader), 0003 (identity,
readiness, decoders), 0005 (the feed's poster), 0006 (the viewer's pages).
