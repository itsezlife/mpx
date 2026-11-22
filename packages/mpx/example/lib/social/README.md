# Social feed

A feed of posts with albums, videos and GIFs over the whole mpx stack: the
asset cache and decoders, the player pool, the feed policy in list and pager
modes, and the fullscreen viewer. It reads the open, signed-out Mastodon API,
so it needs **no key and no account**.

```shell
cd packages/mpx/example
flutter run -t lib/social/main.dart
```

The app opens dark and stays dark.

## What it shows

- **Feed** (tabs): trending, albums (posts with two or more attachments),
  photography, wildlife, art, GIFs. Pull to read again, scroll to page.
  A hashtag in a post opens its timeline.
- **Albums**: one to four media per post, laid out as a chat album does
  (`AlbumLayout`). Every media is an item of the feed: a clip plays muted and
  loops while it shows; a tap opens the viewer on it, with the author, the
  description, a thumbnail strip and share.
- **Sound**: a speaker on a video gives it the sound (`InlineSound` over the
  pool's one sound owner); the next clip in view takes it, until the reader
  switches it off.
- **Reels**: one video at a time over the whole page, with sound. A tap mutes,
  a double tap likes (a heart bursts where it landed), a press holds the video
  still, and a seek bar along the bottom edge is dragged to seek (the viewer's
  own `ViewerSeekBar`, restyled as a hairline). Every video plays by itself;
  while one loads it shows the buffering spinner and nothing else.
- **Text**: a long press and a drag select text, across posts (`flutter_md`'s
  selection over the list). It ends when the list leaves the screen.
- **Covered posts**: a content warning or sensitive media are not fetched until
  the reader asks.
- **Logs**: the bug-report icon opens the journal of what the app logged.

## Layout

| Where | What |
| --- | --- |
| `bootstrap.dart`, `main.dart` | The entry: the logger, the guarded zone, the error screen |
| `src/feature/initialization/` | `Dependencies`, filled by the ordered steps of `$initializeDependencies`; one `ControllerObserver` |
| `src/feature/timeline/` | Posts: `data/` (client, DTOs, adapter, repository), `model/`, `controller/`, `widget/` |
| `src/feature/reels/` | The pager of videos |
| `src/feature/logs/` | The log journal over `LogBuffer` |
| `src/feature/app/` | The routes (one list, `squid`) and the home |
| `src/common/` | The theme, media keys' origins, formatting, small widgets |

Media are keyed by `MediaKey.external('<server>/media/<id>')`, never by URL;
`MediaOrigins` is the host's map from a key to where it lives.

## What the stack still lacked, and what is left

Found building it. Fixed in the packages, in this change:

- **`FeedPager.held` was wiped by the feed** on every measure, so a host could
  not hold a reel still. The policy's hold is now `FeedPager.pausedByPolicy`.
- **The viewer's seek bar could not be reused.** It is now `ViewerSeekController`
  and `ViewerSeekBar` (`mpx_ui`), restyled by `ViewerSeekBarStyle`.

Worked around here, in the app:

- **The viewer has no sound switch.** Its video page plays with sound and has
  no mute control; the feed and the reels have their own.
- **List mode plays only muted.** Sound in a list is the host's: a lease from
  the pool over the tile, as `InlineSound` does.
- **A pager that is not shown goes on playing**: its slots measure as hidden,
  and the page that played keeps playing. The reels are built only while their
  tab shows.
- **The reference autoplay gate holds a large video back until a tap**, which
  on a page with no button is a black page. The reels pass a gate that plays
  every video when there is a network.
- **No inline embed seam for text.** `flutter_md` paints custom emoji through
  `MarkdownInlineEmbed`; an mpx asset has no such adapter, so a server's custom
  emoji show as their `:shortcode:`.

In `flutter_md` (not this repository):

- Its text's render object becomes a repaint boundary when it gets a selection
  controller, after the compositing bits are settled, so a `ClipRect` above it
  does not clip it (clamped text painted past its cut). `PostTextView` puts a
  `RepaintBoundary` of its own inside the clip.
- Its selection toolbar, left in the overlay when the list went off screen,
  painted with NaN anchors on every frame. `PostSelectionScope` ends the
  selection when the list stops being what the reader sees.
