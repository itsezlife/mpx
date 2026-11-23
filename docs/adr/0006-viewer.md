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
**Relates to**: 0001, 0004, 0010
**Amended**: 2026-11-14, composable pieces (ticket 50); 2026-11-17, loading
stages (ADR 0010); 2026-11-18, the gallery pager and its gestures; 2026-11-23,
the seek bar as a piece of its own

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
| Dismiss | Either way, past H/6, no velocity; background alpha floor 127 | Either way, past H/4 or \|v\| > 1 pt/ms; swipe up may start PiP | Click anywhere off the controls |
| Zoom | Double tap 3x around the point; pinch 1-3 | Fit, max(fill, 3x min), 4x for tiled originals | Integer steps to 8x plus fit |
| Double tap on video | ±10 s in the outer thirds (duration > 15 s) | ±15 s, split at 0.3·W | Fullscreen toggle |
| Controls on open | Visible; video hides after 3 s | Hidden for video, shown for photo | Visible |
| Auto-hide | 3000 ms (1000 if not autoplayed) | 4.0 s | 1100 ms wait, 600 ms fade |
| Speed | Slider 0.2-3.0 + presets 0.2-2.0 | Slider 0.2-2.5; hold = +1x | Slider 0.5-2.5; hold 200 ms = 2x |
| Speed persistence | Per item | Shared across items | Global |
| Loop | Video ≤ 30 s, or saved toggle | ≤ 30 s | Silent video loops |
| Seek preview | Yes, 150 dp long side | Yes, fit 160x90 | No |
| PiP | Own floating window + system PiP | System `AVPictureInPictureController` | System `AVPictureInPictureController` on macOS (the reference's own 320 px window needs multi-window) |

**Loading** (`ViewerPolicy.loading`, ADR 0010):

| Value | `$Android` | `$IOS` | `$Desktop` |
| --- | --- | --- | --- |
| control | 64, spinner for photos | 50, black 0.5 | 50, photo progress after 350 ms |
| buffering | after 500 ms, 200 ms fade | after 500 ms | after 500 ms, 500 ms fade |
| status | central page only | central page only | central page only |
| player fade-in | 200 ms (100 handed over) | 100 ms | 0 |

### Host seams

| Seam | Contract |
| --- | --- |
| `GallerySource` | Indexed; loads both ways; total count for "5 of 120". A `Listenable` with `count`, `itemAt(index)` (null while not loaded) and `loadAround(index)`; items are `GalleryItem(key, kind, size, descriptor)`; a descriptor given reaches the pipeline before the page attaches |
| `OriginBridge` | For any index: rect, corner radius and clip (`GalleryOrigin`), and the bubble's current frame (`frameOf`, a `ui.Image` the caller owns: each call hands out a clone, so the bridge freeing its copy never frees one the viewer paints; the viewer keeps its copies for the item and its neighbours and frees the rest). Contract suite: `OriginBridgeContract`. When the viewer closes on another item, `reveal(index)` gives the host a chance to build an origin it has not built; the list is never scrolled to an origin it has (the reference flies to where the item is, or fades when it shows nothing); `setHidden(index, hidden:)` hides the bubble while the viewer's copy covers it |
| Actions | The host supplies the action set and handlers per index (`ViewerAction`: label, icon, handler, in the bar or the menu) |
| Files | A host callback `openFile(key) -> ViewerFile?` (`path`, `release`); the host wraps the bytes cache's file lease in it, so `mpx_ui` takes no cache dependency. The viewer releases files an action opened when the action completes |
| Caption and author | Builders; rich text stays on the host's side |
| Tokens | Colours and typography from the host (`ViewerTokens`, defaulting to the Android reference's values); no `chrome_foundation` dependency |
| Backdrop | The viewer reports the scale the host draws its surface at (`onBackdropScale`); it cannot reach the surface itself |

The viewer knows nothing about chats or messages.

### Composable pieces

A host opens the viewer from any list without writing a bridge, and uses its
pages in its own screens. `MediaViewer` stays the assembled default.

| Piece | Contract |
| --- | --- |
| `ViewerOrigin`, `ViewerOriginScope` | An origin wraps a thumbnail anywhere and registers by gallery index or `MediaKey`; the scope implements `OriginBridge` for them (`bridgeFor(source)` resolves keys through the viewer's gallery). Rect from the origin's own box in global coordinates; clip = the intersection of every enclosing `RenderAbstractViewport`; no place when fully clipped or not painted, so the viewer falls back to the fade; the frame is the origin's `RepaintBoundary` read synchronously when asked; the one read as the origin is hidden is kept, per gallery and index, until the origin shows again, since a hidden origin paints nothing to read; hidden = opacity 0 while laid out; `reveal` does nothing for a built origin (no scroll: the close flies to the part that shows, or fades), else the host's `onReveal(index)`, then one frame; hand-back and start position are callbacks on the origin. A host may still pass its own bridge |
| `ViewerController` | Attached while a viewer is mounted: `index`, `isOpen`, `controlsVisible` (settable), `videoLease`; `jumpTo`, `animateTo`, `resetZoom`, `close`. Notifies on item, open state, controls and lease changes |
| `MediaViewer.show` | Pushes the transparent route; without a bridge it uses the closest `ViewerOriginScope`, without a policy `ViewerPolicy.forPlatform` |
| `ViewerPhotoPage` | Embeddable: dismiss drag, max zoom, content size and the zoom callback are optional; a host pager stops paging while it reports a zoom. Under a `GalleryPageScope` it is that pager's `GalleryPageGestures`; alone it runs the gallery's gesture owner itself, paging off |
| `GalleryPager` | The viewer's pager, public for any host (the feed pager uses it): count, page builder, axis, gap, physics, transition, tap rules, keep-alive, dismiss claim and callbacks, text direction; `GalleryPagerController` (`page` lands with the settle, continuous `position`, `animateTo`, `jumpTo`, `nextPage`, `previousPage`) |
| `ViewerVideoSession`, `ViewerVideoPage` | The session is the video logic (lease, loop and end rules, auto-hide, seek, speed, quality, double-tap seek, held press) that `MediaViewer` and the page share; the page is a photo page over the player with the policy's controls, playing only while `active` |

### Configuration

Every behaviour is a field of `ViewerPolicy`, a full value per platform
(`$Android`, `$IOS`, `$Desktop`). A host changes one with `copyWith`, which
the policy and every value in it have, and sets it for the viewers below a
`ViewerPolicyScope`, whose function receives the platform's reference and
returns the policy: a change relative to the platform, or a whole
replacement. A viewer follows its own `policy`, else the closest scope's,
else the reference of the theme's platform (`ThemeData.platform`, so a theme
that overrides the platform gets that viewer). Anything a host does not set
stays the platform's.

Rejected: a mirror class of nullable fields merged over the platform's
policy. It is a second copy of every field to keep in step with the first,
and a second place a value could come from; with `copyWith` the policy stays
the one source of truth.

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
| Save, share | Host, on every platform: permissions, gallery and share plugins are the app's choice. The package hands the host the cached file (`ViewerActionRequest.file`, a `ViewerFile` over the bytes cache's file lease) and the current frame (`frame()`, the picture as shown); the example implements both |

### Playback

Video plays through the player pool and the audio owner (ADR 0004); opening
from a bubble is the hand-off there. GIFs loop muted with no controls on the
software path.

An animation's page binds the spec the bubble binds (`AssetPresets.animation`,
ADR 0003), so it draws the bubble's own entry: one playback in two places.
An item whose bubble is gone gets its own entry at the same spec.

While the player plays a video with sound, the bubble's loop of it never
plays underneath: it stands still on its frame
(`AssetCacheScope.holdPlayback`), one decode of the content at a time, as on
every reference. The page shows that frame until the player's first, and the
morph carries the player's picture both ways. The references differ on the
rest, so these are policy values (`ViewerVideoRules`):

| Value | `$Android` | `$IOS` | `$Desktop` |
| --- | --- | --- | --- |
| `start`: where the player of a video with sound starts | `beginning` | `beginning` | `beginning` |
| `originReturn`: the bubble's loop on close | `atPlayer` | `restart` | `atPlayer` (unconfirmed in the reference) |
| `loopOpen`: an animation on open | `continues` | `restart` | `continues` |

- `start`: no reference starts a video with sound at the bubble's position;
  each starts at the beginning or at a place it saved. `origin` (the
  origin's `GalleryOrigin.position`, else the loop's position in the cache)
  stays an option. A saved place is the host's data, not policy:
  `MediaViewer.videoStartOf` gives one, `onVideoLeft` reports where the
  viewer left the item.
- `originReturn`: `atPlayer` hands the player's position back
  (`OriginBridge.handBack`) and seeks the loop there
  (`AssetCacheScope.seekPlayback`), showing the player's last picture until
  the loop's own frame there is drawn; the silent clip seeks for real (ADR
  0003). `restart` plays the loop from its first frame; `whereItPaused`
  goes on from its frame.
- `loopOpen`: `continues` shares the bubble's playback; `restart` shares it
  and starts it over as the viewer opens and closes; `own` plays an entry of
  the page's own from its first frame.

The web has no policy of its own yet: `ViewerPolicy.forPlatform` takes the
platform the browser runs on. Its reference behaves like the desktop for
input and differs elsewhere (speeds up to 5x, loops under 60 s, a drag that
pauses and seeks live, its own playback of an animation from frame 0); it
needs a policy of its own.

The morph runs between the picture as the origin shows it (`GalleryOrigin.fit`:
the origin's box when it covers it, the part it fills when it shows the
picture whole) and the picture fitted into the viewer, at the content's own
proportion: the item's size, else the picture a cache entry of it draws
(`AssetCacheScope.pictureSizeOf`), else the player's, else the origin's frame
or box.

### Downloads on a page

- The page shown asks for its content while it shows it
  (`AssetView.requestsDownload`, ADR 0010): opening the viewer, or paging
  to a photo or an animation, is the user's request to see it, whatever the
  auto-download policy said in the list. A video asks only when it is the
  item the viewer opened on, known by its content (`MediaKey`), not by its
  index, which moves when the source learns of items before it; a video
  paged to follows the policy (a player streams it, else the page offers
  the download). The neighbours follow the policy.
- **Viewer-close rule**: a page's request ends with the page. A download
  only it started stops on close or paging away, keeping its bytes, and the
  origin's tile offers the download with them. A download the user asked
  for (the page's download control) is the user's: it goes on after the
  viewer closes, with no surface attached, until the content is whole,
  cancelled or failed, and the tile shows it. A cancel wins over the
  page's request.
- The page's status (`ViewerPageStatus`) reads the content's one transfer
  through an entry of the page's spec. It reads without side effects; the
  photo-progress delay and the `shows` signal change only when the status
  does, and a change heard while another widget builds is shown after
  that frame. A video has one centre control: the download radial until
  the player's first frame, the buffering spinner held back while it shows.

The origin's frame (`OriginBridge.frameOf`) is the page's placeholder and
outranks the content's preview and thumbnail until the first frame. Without
it the page shows the preview, then the thumbnail, fitted to the media's
proportion on the black page. A page never shows a box. Content with
transparency fades its stand-in out as it rises (ADR 0010).

### Gallery pager and gestures (amendment 2026-11-18)

The viewer pages on `GalleryPager` (`mpx_ui/lib/src/gallery/`), not
`PageView`: the stock pager's drag recognizer and each page's scale
recognizer raced for the arena, so a vertical swipe could start the page and a
zoomed picture could never hand on at its edge.

**One gesture owner.** `GalleryGestureRecognizer` is the only drag and scale
recognizer over the media. It decides once, on the straight line from the
down point, and the first rule that holds locks for the gesture:

1. a second finger, on a page that zooms, while no neighbour shows past 5 px:
   pinch;
2. one finger on a zoomed picture, past the tap slop: pan;
3. else the dismiss claim (tested first), then the page claim.

The distance that decided is swallowed: the picture does not jump. A touch
that never decides is never claimed, so the gallery's one
`GalleryTapRecognizer` beside it, and controls inside the pages, get it.
Controls that must never page or dismiss (the seek bar, the bars, the speed
panel) sit above the pager as siblings, outside its arena.

**Hand-off.** A zoomed picture takes a pan until it is pinned at its edge
toward a page that exists; the pager takes the rest, and the pan brings the
pager back to rest before the picture moves again. The release then follows
the pager's rule (by distance only where the policy says so). Toward a side
with no page the picture follows past its edge, damped, and snaps back. A
vertical pan of a zoomed picture never dismisses. The page left resets its
zoom when the settle lands.

**Taps.** One tap recognizer per pager: the single tap waits for a second
press only where a double tap does something (a photo's zoom, a video's
seek), and the double tap fires on the second press; side strips page at
once; a held press the page takes (a video's speed-up) wins the arena, so
its moves page and dismiss nothing.

**Values** (`ViewerPolicy.pager`, `transition`, `taps`, the zoom and dismiss
fields):

| Value | `$Android` | `$IOS` | `$Desktop` |
| --- | --- | --- | --- |
| Page claim | `\|dx\| > \|dy\| + 12` | 10 pt slop, more across than down | none (instant) |
| Dismiss claim | 30 px, twice as vertical | 10 pt slop, more down than across | none |
| Transition | stack: next under, 0.7 to 1, fading; previous over | strip, 0.16 parallax | instant |
| Gap | 15 | 40 | 0 |
| Ends | a third of the drag | rubber band (0.55) | hard |
| Release | a third, or 650 px/s; distance only while zoomed | half, or 300 pt/s (platform snap, approximated) | n/a |
| Settle | 250 ms, decelerate | 400 ms critically damped spring (platform deceleration, approximated) | 0 |
| Touch during a settle | ignored | catches it | n/a |
| Side taps | `min(135 px, W/8)`, below the bars, on lift | none (off by default) | 90 px strips clear of 47 px bars, on press |
| Single tap waits | 300 ms (40 ms minimum gap, 100 px slop) | 160 ms | 300 ms, where a double click acts |
| Pinch | focal fixed at the start, no live limit, snap on release | focal follows, two-finger pan, bounce past the limits | trackpad: a step per 0.25 of scale |
| Zoomed fling | yes, within the bounds | yes | none (a mouse drag pans, clamped) |
| Video double tap | seek, middle zooms | seek, never zooms | fullscreen |
| Held press | 300 ms, video of 8 s or more, right two thirds: 2x | 300 ms, right 60%: +1x | 200 ms: 2x |

Desktop: the arrows and a wheel notch switch one item at once (Home and End
do nothing, as on the reference); a trackpad's vertical pan pages every
120 px, its horizontal swipe goes once past 17.5 px of a fifth of the pan;
Ctrl with the wheel or a trackpad pinch zooms at the cursor; a click
anywhere off the controls closes, on a video it plays or pauses; the cursor
is a hand over a strip that pages, a move cursor while a zoomed picture pans,
and hidden with a video's controls.

Two values were wrong before and are fixed: `$Android.dismissDownOnly` is
false (the reference reads the drag's absolute offset) and
`$IOS.dismissFraction` is 1/4 (the reference divides a scroll content three
heights tall by 12).

Kept: the origin morph, the loading stages and the one centre control, the
neighbours' preparation once a settle lands (`onPageChanged` fires then, as
both mobile references switch their item after the settle), the chrome.

RTL: the references never mirror the gallery, so the viewer pages left to
right in any locale; `GalleryPager.textDirection` mirrors the order for a host
that asks. Semantics: the pager exposes scroll actions for the next and
previous page.

Not covered yet: the desktop trackpad swipe's arrow bubble (the commit rule
is there, the visual is not); the Android hold's back-seek on the left third
and the hold-and-drag speed scrub; a long-press or right-click menu (no
mobile reference has one; the desktop's right click is open); the desktop
touchscreen swipe.

Rejected: a scale recognizer per page beside a pager drag recognizer (the
race above); nested scrollables imitating the iOS structure (three
`Scrollable`s would race the same way, and the other platforms are not
nested); a strip for every platform (the Android reference stacks its pages).
Evidence, with file and line in the references: research
`media-viewer-gestures/reference-gestures` (chat_scroll_view `.scratch`).

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

### Implemented as (tickets 36-38)

`ViewerPolicy` grew `openStyle` (`morph` / `reveal` / `appear`),
`backgroundFadeDuration`, `dismissDrag`, `dismissVelocity`,
`backgroundFadeDistance`, `backgroundClickCloses`, `zoomRule`
(`fixed` / `fill` / `steps`), `doubleTapEdgeInset`, `controlsHideDuration`,
`desktopInput` and `video` (`ViewerVideoRules`: controls on open, auto-hide,
`ViewerDoubleTapSeek`, double tap for fullscreen, `ViewerSpeedRule`,
`ViewerHoldSpeed`, the loop rule, the seek-preview box). `$IOS` and
`$Desktop` sit beside `$Android`. Video plays through `MediaViewer.players`
(the item on screen holds a playing lease from before the open morph's
first frame; with `ViewerVideoRules.prepareNeighbours`, on by default,
the video items beside it hold paused, prepared leases while the viewer
is open, up to the pool's prepared budget, the next first, once the item
shown has its first frame), hands off from the origin
(`GalleryOrigin.position`, `OriginBridge.handBack`), and is drawn under
`ViewerVideoControls`. Fullscreen on desktop is the host's window through
`MediaViewer.onFullscreenChanged`; the package takes no window plugin.

## Open in implementation

- Desktop colour values and fade/slide durations: the toolkit's style and
  palette files are absent from the reference checkout.
- Android open/close interpolators are unset in source (framework default
  inferred).
- Quality list source: answered as a host callback,
  `MediaViewer.qualitiesOf(index, item) -> [ViewerQuality(label, key)]`;
  choosing one leases the other key at the same position.
- The strings seam's shape: `ViewerStrings` (chrome) and
  `ViewerVideoStrings` (controls) for now; one strings object later.
- Desktop zoom below the fitted size (the reference goes down to 1/8 of the
  picture's pixels) is not offered: steps start at fit.
- Instant-view galleries, stories and secret media: not covered.

## Provenance

Planning tickets `04`, `11`, `22` (macOS form, save and share); research `04-viewer-anatomy`
(every constant with file:line, divergence table, gaps). The iOS gallery
sources are read with `git show HEAD:` in the sparse checkout.

## Related

ADR 0004 (pool, audio owner, hand-off, PiP plumbing).

## Amendment 2026-11-23: the seek bar as a piece of its own

The seek bar was a private part of `ViewerVideoControls`, and a surface that
wanted the viewer's bar (a reels page along its bottom edge) had to copy its
rules. It is now two public pieces in `mpx_ui`, by the headless-behaviour rule
of the package:

| Piece | Role |
| --- | --- |
| `ViewerSeekController` | The rules, with no widget: the playhead read from the lease each frame while it plays, a preview that a finger moves, the seek made once when the finger leaves (not one per touch event), the length from the player else the host's |
| `ViewerSeekBar` | The skin: the track, the buffered ranges, the progress and the thumb, dragged or tapped, drawn as a `ViewerSeekBarStyle` says (track and thumb sizes, where the track sits in the touch target, how faint the rest is) |

The viewer's controls use both with the default style, which is the bar as it
was; the time and the preview frame stay the controls', read from the same
controller. A reels page uses them with a hairline style and holds its pager
while the preview is set.

## Amendment 2026-11-23: speed, system bars and the cell that follows the page

Three decisions from running the viewer in a messenger-like feed:

- **Speed is a cycle and a menu.** The panel with a slider under the caption
  was a prototype. A button beside the seek bar goes through
  `ViewerSpeedRule.cycle` (1x, 1.5x, 2x); every other speed
  (`ViewerSpeedRule.presets`, 0.25x and 0.5x among them) and the qualities
  are in a settings menu opened from a button under the top bar. No free
  slider: a speed is one of a list.
- **System bars are the viewer's while it is open.** `MediaViewer.systemBars`
  hides the status bar (`ViewerSystemBars.hideStatusBar`, the default) with
  the controls and restores it edge to edge when the viewer closes. The
  navigation bar stays clear and the pictures run under it; the viewer's
  scrim (the bars' fill) draws over it with the controls, and the picture
  shows through without them, as in the reference. The controls (the video
  bar, the caption) sit above it.
- **The surface's hidden cell follows the page.** The origin of the item on
  show is the one hidden; paging hides the new one and shows the one left, so
  a close onto another item flies from an empty place to its cell, as the
  reference does.

## Amendment 2026-11-23, second pass: the chrome as one block

Read against the reference's viewer:

- **Only the status bar goes** (`ViewerSystemBars.hideStatusBar`, the
  default). The reference hides the status bar with its controls and keeps
  the navigation bar (it hides that only in landscape with side insets);
  `hideAll` is for a host that wants the immersive mode.
- **The caption is a scroll view, as the reference's `CaptionScrollView` is.**
  It fills the room between the top bar and the video controls; its text
  starts as low as five lines (two in landscape) and scrolls up over the
  picture, the box behind it following the text. A pull past an end gives
  (a finger's move followed by `1 - |over| / room` of itself, the room being
  the space above the text at rest, as the reference's `dispatchNestedScroll`
  does; the spring is `BouncingScrollPhysics`': stiffness 100, no bounce of
  its own) also when
  all of the text shows and there is nothing to scroll, as the reference's
  does; its edges fade (12 px) while there is more text.
  Touches above the box fall through to the picture. A first design that grew
  a box and then scrolled the text, with a hand-made rubber band, let a pull
  take the text far up; it is gone.
- **The chrome fades in with the open morph**, as the reference's container
  does (alpha 0 to 1 over the 200 ms), not when it ends.
- **One block hides.** The caption, the strip and the video bar slide by
  `controlsSlide` over the same duration and curve, so there is never a gap
  between their containers while the controls go.
- **The settings button is in the top bar**, with the overflow button, not
  under it; the panel opens under the bar at its right edge. A menu or the
  settings keeps the controls shown (`ViewerVideoSession.hold`): the
  auto-hide wait starts again when they close.

