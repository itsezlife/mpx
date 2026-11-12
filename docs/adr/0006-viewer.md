# ADR 0006: The fullscreen viewer

The viewer in `mpx_ui` is one fullscreen viewer structure driven by three pure
policies: `$Android`, `$IOS` and `$Desktop`. Each platform follows its own
reference client by default (Android from the Android client, iOS from the iOS
client, macOS from the desktop client); a host may pick any policy on any
platform. The host supplies a gallery source and an origin bridge, the actions
per item (save and share among them) and the caption builders. The package
draws the bars, menu and caption, and owns speed, quality, PiP and rotation.
On macOS the viewer is an in-app overlay over the whole app window.

**Status**: Accepted (decided with the maintainer 2026-11-10)
**Relates to**: 0001, 0004

## Context

The map requires the viewer and everything around it to match the reference
1:1. The three reference clients ship three different viewers: different
open/close transitions, dismiss gestures, zoom, double-tap seek, auto-hide
timings and PiP. "1:1" therefore needs a reference per platform or one canon.

## Decision

### Canon

| Platform | Reference | Policy |
| --- | --- | --- |
| Android | The Android client | `ViewerPolicy.$Android` |
| iOS | The iOS client | `ViewerPolicy.$IOS` |
| macOS | The desktop client | `ViewerPolicy.$Desktop` |

The policies are pure Dart values (the `$Mobile` / `$Desktop` shape used for
selection policies): gestures, transitions, constants, auto-hide, loop rule,
speed persistence, PiP flavour. No platform reads.

### What the policies hold

Constants with file and line: research `04-viewer-anatomy`.

| Behaviour | `$Android` | `$IOS` | `$Desktop` |
| --- | --- | --- | --- |
| Open from the bubble | Hero morph, 200 ms (clip and radius); chat behind scales to 1.1 | Two bubble snapshots + bounds reveal, 0.21-0.25 s spring; background fades in 0.15 s | None; the overlay shows |
| Dismiss | Down only, past H/6, no velocity; background alpha floor 127 | Either way, past H/12 or \|v\| > 1 pt/ms; swipe up may start PiP | Background click |
| Zoom | Double tap 3x around the point; pinch 1-3 | Fit, max(fill, 3x min), 4x for tiled originals | Integer steps to 8x plus fit |
| Double tap on video | ±10 s in the outer thirds (duration > 15 s) | ±15 s, split at 0.3·W | Fullscreen toggle |
| Controls on open | Visible; video hides after 3 s | Hidden for video, shown for photo | Visible |
| Auto-hide | 3000 ms (1000 if not autoplayed) | 4.0 s | 1100 ms wait, 600 ms fade |
| Speed | Slider 0.2-3.0 + presets 0.2-2.0 | Slider 0.2-2.5; hold = +1x | Slider 0.5-2.5; hold 200 ms = 2x |
| Speed persistence | Per item | Shared across items | Global |
| Loop | Video ≤ 30 s, or saved toggle | ≤ 30 s | Silent video loops |
| Seek preview | Yes, 150 dp long side | Yes, fit 160x90 | No |
| PiP | Own floating window + system PiP | System `AVPictureInPictureController` | System `AVPictureInPictureController` on macOS (the reference's own 320 px window needs multi-window) |

### Host seams

| Seam | Contract |
| --- | --- |
| `GallerySource` | Indexed; loads both ways; total count for "5 of 120" |
| `OriginBridge` | For any index: rect, corner radius, clip and the bubble's current frame. When the viewer closes on another item, the host scrolls its list to that item's origin first |
| Actions | The host supplies the action set and handlers per index (icon, label, handler) |
| Caption and author | Builders; rich text stays on the host's side |
| Tokens | Colours and typography from the host; no `chrome_foundation` dependency |

The viewer knows nothing about chats or messages.

### macOS form

| Area | Decision |
| --- | --- |
| Form | An in-app overlay over the whole app window, with the desktop client's behaviour: background click closes, keyboard shortcuts, desktop controls and zoom steps |
| Fullscreen | Puts the app window itself into fullscreen |
| PiP | The system `AVPictureInPictureController` on the player |
| Windows | No multi-window Flutter in v1 |

### Chrome and built-in actions

The package draws the top bar, bottom bar, menu, caption area and group
thumbnail strip in each reference layout. Speed, quality, PiP and rotation are
the package's own actions.

| Action | Owner |
| --- | --- |
| Speed, quality, PiP, rotation | Package |
| Save, share | Host, on every platform: permissions, gallery and share plugins are the app's choice. The package hands the host the file path in `http_bytes_cache` and the current frame; the example implements both |

### Playback

Video plays through the player pool and the audio owner (ADR 0004); opening
from a bubble is the hand-off there. GIFs loop muted with no controls and
continue the bubble's animation (software path), as on every reference client.

## Why

- Users of each platform know their own client. A single canon would look
  foreign on two of three.
- The differences are values and gesture rules, not structure, so one viewer
  with three policies costs far less than three viewers.
- Pure policies are testable as values and let a host choose, say, the iOS
  feel on Android.
- An in-app overlay keeps macOS on the same structure as mobile; a separate OS
  window waits on Flutter multi-window.
- Save and share need permissions and plugins each app chooses differently;
  the package keeps no plugin dependency for them.
- The two seams are the minimum a viewer needs from a list: what to show, and
  where it came from.

## Rejected

| Alternative | Why not |
| --- | --- |
| One canon for all platforms | Foreign on two platforms; the map asks for 1:1 |
| Three separate viewers | Duplicates paging, zoom, chrome and playback |
| The viewer knowing the chat (message ids, scroll controller) | Breaks the portable surface |
| Host-drawn bars and menu | Each host would redo the reference layout |
| Policy as platform-forked code (`_vm`/`_js`) | The differences are not native |
| A separate OS window on macOS in v1 | Needs Flutter multi-window |
| Built-in save and share | Pulls gallery, share and permission plugins into the package |

## Consequences

- Three sets of motion and gesture tests, one per policy.
- The origin bridge asks hosts for the bubble's current frame; chat_scroll_view
  provides it from the core's binding.
- The macOS `$Desktop` policy departs from its reference in form and PiP: no
  separate window, no own PiP window.
- Hosts implement save and share; the example shows how.
- Strings for built-in actions (speed, quality, PiP, rotation, "N of M") need a
  host-supplied strings object.

## Open in implementation

- Desktop colour values and fade/slide durations: the toolkit's style and
  palette files are absent from the reference checkout.
- Android open/close interpolators are unset in source (framework default
  inferred).
- Quality list source: how the host or the player exposes alternatives.
- The strings seam's shape.
- Instant-view galleries, stories and secret media: not covered.

## Provenance

Planning tickets `04`, `11`, `22` (macOS form, save and share); research `04-viewer-anatomy`
(every constant with file:line, divergence table, gaps). The iOS gallery
sources are read with `git show HEAD:` in the sparse checkout.

## Related

ADR 0004 (pool, audio owner, hand-off, PiP plumbing).
